#!/usr/bin/env bash
set -e

# =========================================================
# DevBlog — Nx Monorepo Bootstrap Script (pnpm, Ubuntu)
# Assumes: empty folder, terminal already open inside it,
# Nx installed globally, pnpm as package manager.
# =========================================================

WORKSPACE_NAME="${1:-Phase-1}"

echo "🚀 Starting DevBlog Nx workspace setup: $WORKSPACE_NAME"
echo "-----------------------------------------------------"

# ---------------------------------------------------------
# 1. Sanity check — target folder must be empty (or not exist).
#    This script is meant to run from the PARENT directory of
#    your project folder (e.g. run from ~/Documents/Projects,
#    targeting the empty ./Phase-1 subfolder).
# ---------------------------------------------------------
if [ -d "$WORKSPACE_NAME" ] && [ "$(ls -A "$WORKSPACE_NAME" 2>/dev/null)" ] && [ ! -f "$WORKSPACE_NAME/nx.json" ]; then
  echo "❌ '$WORKSPACE_NAME' already has files in it. Empty it first, or pass a different name:"
  echo "   ./setup-devblog.sh <folder-name>"
  exit 1
fi

# ---------------------------------------------------------
# 2. Create Nx workspace directly in the target subfolder
#    (skip if it already exists — makes the script resumable)
# ---------------------------------------------------------
if [ -f "$WORKSPACE_NAME/nx.json" ]; then
  echo "ℹ️  Workspace already exists at ./$WORKSPACE_NAME — skipping creation, resuming setup."
else
  pnpm dlx create-nx-workspace@latest "$WORKSPACE_NAME" \
    --preset=apps \
    --packageManager=pnpm \
    --nxCloud=skip \
    --interactive=false
fi

cd "$WORKSPACE_NAME"

echo "✅ Nx workspace ready."

# ---------------------------------------------------------
# 2b. Pre-approve native build scripts (pnpm security feature).
#     Newer pnpm (v10+) uses "allowBuilds" (map of pkg -> bool)
#     in pnpm-workspace.yaml — NOT package.json's "pnpm" field,
#     and NOT the older "onlyBuiltDependencies" list format.
#
#     NOTE: create-nx-workspace already generates its own
#     pnpm-workspace.yaml with an "allowBuilds" key (usually
#     just { nx: true }). A plain `grep -q "allowBuilds"` check
#     therefore matches immediately and skips adding the rest of
#     our required packages (@parcel/watcher, sharp, less, etc.),
#     which is why those kept showing up as ERR_PNPM_IGNORED_BUILDS
#     even though the script claimed "already configured".
#
#     Fix: force-patch the file with a small Node script that
#     ensures each required package is present AND set to `true`,
#     regardless of what's already in the file — additive, and
#     idempotent, so it's safe to re-run.
# ---------------------------------------------------------
echo "🔧 Pre-approving native build scripts (pnpm-workspace.yaml)..."
touch pnpm-workspace.yaml

REQUIRED_BUILD_PKGS="@parcel/watcher less sharp unrs-resolver esbuild bcrypt @swc/core nx protobufjs @apollo/protobufjs grpc-tools"

fix_builds() {
  local pkgs=("$@")
  if [ ${#pkgs[@]} -eq 0 ]; then
    # Called with no args (post-install safety net) — re-assert the
    # same required list rather than doing nothing.
    pkgs=($REQUIRED_BUILD_PKGS)
  fi
  node - "${pkgs[@]}" <<'NODE_EOF'
const fs = require('fs');
const file = 'pnpm-workspace.yaml';
const required = process.argv.slice(2);

let text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
let lines = text.split('\n');

// Locate (or create) the "allowBuilds:" section.
let start = lines.findIndex(l => /^allowBuilds:\s*$/.test(l));
if (start === -1) {
  if (text.trim().length && !text.endsWith('\n')) lines.push('');
  lines.push('allowBuilds:');
  start = lines.length - 1;
}

// Section runs until the next top-level (non-indented, non-blank) key.
let end = lines.length;
for (let i = start + 1; i < lines.length; i++) {
  if (lines[i].trim() !== '' && !/^\s/.test(lines[i])) { end = i; break; }
}

const keyOf = (line) => {
  const m = line.match(/^\s*['"]?([^'":\s]+)['"]?\s*:/);
  return m ? m[1] : null;
};

for (const pkg of required) {
  let found = false;
  for (let i = start + 1; i < end; i++) {
    if (keyOf(lines[i]) === pkg) {
      lines[i] = `  '${pkg}': true`;
      found = true;
      break;
    }
  }
  if (!found) {
    lines.splice(end, 0, `  '${pkg}': true`);
    end++;
  }
}

fs.writeFileSync(file, lines.join('\n'));
NODE_EOF
  # Patching the yaml only takes effect on the *next* install; force any
  # already-installed packages in this list to run their build scripts now.
  pnpm rebuild "${pkgs[@]}" >/dev/null 2>&1 || true
}

fix_builds $REQUIRED_BUILD_PKGS
echo "  ✓ allowBuilds patched for: $REQUIRED_BUILD_PKGS"

# ---------------------------------------------------------
# 2. Install Nx plugins needed for our stack
# ---------------------------------------------------------
echo "📦 Installing Nx plugins (nest, next, js)..."
pnpm add -Dw @nx/nest @nx/next @nx/js @nx/node
fix_builds

# ---------------------------------------------------------
# 3. Generate NestJS microservices (skip if already generated)
# ---------------------------------------------------------
echo "🏗  Generating backend services..."
gen_nest() {
  if [ -d "apps/$1" ]; then
    echo "  ↷ apps/$1 already exists, skipping"
  else
    nx g @nx/nest:app "apps/$1" --no-interactive
  fi
}
gen_nest gateway
gen_nest auth-service
gen_nest post-service
gen_nest comment-service
gen_nest search-service
gen_nest feed-service

# ---------------------------------------------------------
# 4. Generate Next.js frontend (skip if already generated)
# ---------------------------------------------------------
echo "🎨 Generating frontend app..."
if [ -d "apps/frontend" ]; then
  echo "  ↷ apps/frontend already exists, skipping"
else
  nx g @nx/next:app apps/frontend --style=css --no-interactive
fi

# ---------------------------------------------------------
# 5. Generate shared libs (skip if already generated)
# ---------------------------------------------------------
echo "📚 Generating shared libs (proto, dto, common, types)..."
gen_lib() {
  if [ -d "libs/$1" ]; then
    echo "  ↷ libs/$1 already exists, skipping"
  else
    nx g @nx/js:lib "libs/$1" --no-interactive
  fi
}
gen_lib proto
gen_lib dto
gen_lib common
gen_lib types

# ---------------------------------------------------------
# 5b. Ensure .gitignore covers secrets and build artifacts.
#     Nx auto-generates/updates .gitignore on workspace create
#     and on every `nx g` call, but its default template only
#     ignores .env.local / .env.*.local — NOT plain ".env",
#     which is exactly what we're about to create per-service
#     in the manual steps. Patch it here (after all generators
#     have run) so our additions aren't touched by Nx rewriting
#     the file. Idempotent — safe to re-run.
# ---------------------------------------------------------
echo "📝 Ensuring .gitignore covers .env files and build artifacts..."
touch .gitignore
REQUIRED_GITIGNORE_LINES=(
  ".env"
  ".env.*"
  "!.env.example"
  ".pnpm-store"
)
for line in "${REQUIRED_GITIGNORE_LINES[@]}"; do
  grep -qxF -- "$line" .gitignore || echo "$line" >> .gitignore
done

# ---------------------------------------------------------
# 6. Backend dependencies (runtime)
# ---------------------------------------------------------
echo "📦 Installing backend runtime dependencies..."
pnpm add -w \
  @nestjs/microservices @grpc/grpc-js @grpc/proto-loader \
  @nestjs/graphql @nestjs/apollo @apollo/server graphql \
  typeorm @nestjs/typeorm pg \
  mongoose @nestjs/mongoose \
  ioredis \
  class-validator class-transformer \
  bcrypt @nestjs/jwt passport-jwt passport @nestjs/passport \
  @nestjs/config \
  @nestjs/schedule \
  helmet compression \
  nestjs-pino pino-http \
  @nestjs/terminus \
  dataloader
fix_builds
# ---------------------------------------------------------
echo "📦 Installing backend dev dependencies..."
pnpm add -Dw \
  @types/bcrypt @types/passport-jwt @types/compression \
  ts-proto grpc-tools \
  @types/node
fix_builds

# ---------------------------------------------------------
# 8. Frontend dependencies (runtime)
# ---------------------------------------------------------
echo "📦 Installing frontend runtime dependencies..."
pnpm add -w \
  tailwindcss postcss autoprefixer \
  framer-motion \
  @apollo/client \
  @reduxjs/toolkit react-redux \
  react-hook-form zod @hookform/resolvers \
  lucide-react \
  class-variance-authority clsx tailwind-merge tailwindcss-animate
fix_builds

# ---------------------------------------------------------
# 9. Frontend devDependencies
# ---------------------------------------------------------
echo "📦 Installing frontend dev dependencies..."
pnpm add -Dw \
  @types/react @types/react-dom
fix_builds

echo "-----------------------------------------------------"
echo "✅ All apps, libs, and dependencies installed."
echo ""
echo "⚠️  Manual steps still required:"
echo "  1. Run 'npx shadcn@latest init' inside apps/frontend (interactive setup, can't be scripted safely)"
echo "  2. Create .env files per service (DB URLs, JWT secret, Redis URL)"
echo "  3. Write .proto files inside libs/proto"
echo "  4. git init + first commit"
echo "-----------------------------------------------------"
