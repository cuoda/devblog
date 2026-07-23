<div align="center">

# DevBlog

**A distributed, multi-tenant publishing platform engineered for high-concurrency workloads.**

Microservices architecture · GraphQL BFF · gRPC · Polyglot persistence

[![NestJS](https://img.shields.io/badge/NestJS-E0234E?style=flat-square&logo=nestjs&logoColor=white)](#)
[![Next.js](https://img.shields.io/badge/Next.js-000000?style=flat-square&logo=nextdotjs&logoColor=white)](#)
[![TypeScript](https://img.shields.io/badge/TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white)](#)
[![pnpm](https://img.shields.io/badge/pnpm-F69220?style=flat-square&logo=pnpm&logoColor=white)](#)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=flat-square&logo=postgresql&logoColor=white)](#)
[![MongoDB](https://img.shields.io/badge/MongoDB-47A248?style=flat-square&logo=mongodb&logoColor=white)](#)
[![Redis](https://img.shields.io/badge/Redis-DC382D?style=flat-square&logo=redis&logoColor=white)](#)
[![GraphQL](https://img.shields.io/badge/GraphQL-E10098?style=flat-square&logo=graphql&logoColor=white)](#)
[![gRPC](https://img.shields.io/badge/gRPC-4285F4?style=flat-square&logo=googlecloud&logoColor=white)](#)
[![Nx](https://img.shields.io/badge/Nx_Monorepo-143055?style=flat-square&logo=nx&logoColor=white)](#)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](#license)

[Overview](#overview) · [Architecture](#architecture) · [Services](#services) · [Tech Stack](#tech-stack) · [Getting Started](#getting-started) · [Environment Variables](#environment-variables) · [Roadmap](#roadmap)

</div>

---

## Overview

DevBlog is a multi-user publishing platform — comparable in scope to Medium or Dev.to — designed and built as a distributed system rather than a monolith. It supports three roles (**Author**, **Reader**, **Admin**) and is architected against a target load profile of **100k+ monthly active users** and **10k–20k concurrent connections**.

The project is intentionally over-engineered relative to a typical blog CRUD app. The goal is to exercise the same architectural decisions found in production systems at scale: service decomposition, polyglot persistence, cache-aside strategies, database-level access control, and observability — end to end, from the database layer to the reverse proxy.

### Key Features

- 🔐 Role-based access control (Author / Reader / Admin) enforced at the database layer via Row-Level Security
- ✍️ Full post lifecycle — drafts, publishing, soft-delete, tagging
- 💬 Threaded, nested comments modeled on a document store
- 🔎 Full-text search with relevance ranking (English + Hindi)
- 📈 Trending & personalized feed generation with tiered cache TTLs
- ⚡ GraphQL gateway with DataLoader batching to eliminate N+1 queries
- 🔁 Event-driven cross-service consistency (no message broker required)
- 📊 Auditable change history for every content mutation

---

## Architecture

### System overview

```mermaid
flowchart TB
    subgraph Client_Layer["Client"]
        FE["Next.js Frontend<br/>(SSR + CSR)"]
    end

    subgraph Edge_Layer["Edge"]
        NGINX["Nginx<br/>Reverse Proxy / LB"]
        GQL["GraphQL Gateway (BFF)<br/>Auth guard · DataLoader · Rate limiting"]
    end

    subgraph Service_Layer["Microservices — gRPC"]
        AUTH["Auth Service"]
        POST["Post Service"]
        COMMENT["Comment Service"]
        SEARCH["Search Service"]
        FEED["Feed / Notification Service"]
    end

    subgraph Data_Layer["Data Layer"]
        PG[("PostgreSQL<br/>+ PgBouncer")]
        MONGO[("MongoDB")]
        REDIS[("Redis<br/>Cache · Sessions · Pub/Sub")]
    end

    FE -- "HTTPS / GraphQL" --> NGINX
    NGINX --> GQL
    GQL -- "gRPC" --> AUTH
    GQL -- "gRPC" --> POST
    GQL -- "gRPC" --> COMMENT
    GQL -- "gRPC" --> SEARCH
    GQL -- "gRPC" --> FEED

    AUTH --> PG
    AUTH --> REDIS
    POST --> PG
    POST --> REDIS
    COMMENT --> MONGO
    SEARCH --> PG
    FEED --> REDIS
    FEED --> PG

    POST -. "publish: post.deleted" .-> COMMENT
    POST -. "publish: post.published" .-> FEED
    FEED -. "cron: cache refresh" .-> FEED

    style Client_Layer fill:#1a1a2e,color:#fff,stroke:#666
    style Edge_Layer fill:#16213e,color:#fff,stroke:#666
    style Service_Layer fill:#0f3460,color:#fff,stroke:#666
    style Data_Layer fill:#222,color:#fff,stroke:#666
```

### Request lifecycle — publishing a post

A representative end-to-end flow showing the gateway/service/event boundaries in practice:

```mermaid
sequenceDiagram
    autonumber
    participant C as Client (Next.js)
    participant N as Nginx
    participant G as GraphQL Gateway
    participant P as Post Service
    participant DB as PostgreSQL
    participant R as Redis (Pub/Sub)
    participant F as Feed Service

    C->>N: mutation publishPost(input)
    N->>G: forward request
    G->>G: verify JWT, apply rate limit
    G->>P: gRPC PublishPost(dto)
    P->>DB: INSERT/UPDATE post, set status=published
    DB-->>P: OK
    P->>R: PUBLISH "post.published" {postId, authorId}
    P-->>G: PostPublishedResponse
    G-->>N: GraphQL response
    N-->>C: 200 OK
    R-->>F: post.published event
    F->>F: invalidate trending/personalized cache keys
```

### Communication patterns

| Interaction | Path | Protocol | Rationale |
|---|---|---|---|
| Client → API | Frontend → Gateway | GraphQL | Single round-trip for nested, client-shaped data |
| API → Services | Gateway → Microservices | gRPC / Protobuf | Typed contracts, binary payloads, HTTP/2 multiplexing |
| Service → Service | Post → Comment, Post → Feed | Redis Pub/Sub | Decoupled, eventual-consistency side effects |
| Scheduled work | Feed Service | `@nestjs/schedule` (cron) | Deterministic cache refresh without a broker |

---

## Services

| Service | Responsibility | Data Store |
|---|---|---|
| **GraphQL Gateway** | BFF layer — schema stitching, DataLoader batching, JWT verification, rate limiting | — |
| **Auth Service** | Authentication, JWT issuance/refresh, session state, RBAC | PostgreSQL + Redis |
| **Post Service** | Post CRUD, tagging, likes, triggers, Row-Level Security | PostgreSQL |
| **Comment Service** | Nested/threaded comments, async cleanup on post deletion | MongoDB |
| **Search Service** | Full-text search, relevance ranking, bilingual support | PostgreSQL |
| **Feed Service** | Trending posts, personalized feed, cache orchestration | PostgreSQL + Redis |

<details>
<summary><strong>Expand for detailed per-service design notes</strong></summary>

**Auth Service**
Issues short-lived JWTs with refresh rotation; sessions mirrored in Redis for fast revocation checks; login attempts rate-limited per IP/account.

**Post Service**
Owns the canonical schema for users, posts, tags, and likes. Likes are denormalized onto the post row and kept in sync via a database trigger to avoid `COUNT()` on read. Row-Level Security policies restrict draft visibility to the owning author; admins bypass via a dedicated role.

**Comment Service**
Comments are modeled as a document tree in MongoDB, which avoids recursive CTEs for arbitrarily deep reply chains. Validates the parent post's existence via a gRPC call to the Post Service rather than a shared foreign key.

**Search Service**
Uses PostgreSQL's native `tsvector`/`tsquery` with GIN indexes; ranks exact matches above partial matches and supports mixed Hindi/English queries.

**Feed Service**
Generates the trending list from a 7-day rolling window ranked by engagement; personalized feeds are computed from the follow graph. Cache TTLs are tiered — 5 minutes for recent posts, 1 hour for trending — refreshed by a background cron job.

</details>

---

## Data Strategy

DevBlog follows a **database-per-service** model — no service queries another service's data store directly. Cross-service reads happen over gRPC; cross-service side effects propagate via Redis Pub/Sub events.

| Store | Owner(s) | Why |
|---|---|---|
| **PostgreSQL** | Auth, Post, Search, Feed | ACID guarantees, native full-text search, RLS |
| **MongoDB** | Comment, Audit Log | Natural fit for tree-shaped and schema-flexible data |
| **Redis** | All services | Cache, session store, rate limiting, Pub/Sub |

---

## Tech Stack

<table>
<tr>
<td valign="top" width="50%">

**Backend**

| Layer | Technology |
|---|---|
| Framework | NestJS |
| Monorepo | Nx |
| Package manager | pnpm (workspace) |
| Relational store | PostgreSQL 15+ |
| Document store | MongoDB |
| Cache / Pub-Sub | Redis 7+ |
| ORM | TypeORM |
| ODM | Mongoose |
| Service mesh comms | gRPC (`@grpc/grpc-js`, `@nestjs/microservices`) |
| API layer | GraphQL — Apollo Server |
| Validation | class-validator / class-transformer |
| Auth | bcrypt, `@nestjs/jwt`, Passport |
| Scheduling | `@nestjs/schedule` |
| Observability | nestjs-pino, `@nestjs/terminus` |
| Edge | Nginx, PgBouncer |

</td>
<td valign="top" width="50%">

**Frontend**

| Layer | Technology |
|---|---|
| Framework | Next.js |
| Styling | Tailwind CSS |
| Components | shadcn/ui |
| Motion | Framer Motion |
| Data layer | Apollo Client |
| State | Redux Toolkit |
| Forms | React Hook Form + Zod |
| Icons | lucide-react |

**Tooling**

| Purpose | Technology |
|---|---|
| Load testing | k6 / Locust |
| Containerization | Docker Compose |
| CI target | GitHub Actions *(planned)* |

</td>
</tr>
</table>

> **Design note:** There is deliberately no message broker (Kafka/RabbitMQ/BullMQ) in this system. Cross-service async workflows are handled with Redis Pub/Sub for events and cron for scheduled work — sufficient for this system's fan-out requirements without the operational overhead of a broker.

---

## Repository Structure

```
devblog/
├── apps/
│   ├── frontend/              # Next.js application
│   ├── gateway/                # GraphQL Gateway (BFF)
│   ├── auth-service/
│   ├── post-service/
│   ├── comment-service/
│   ├── search-service/
│   └── feed-service/
├── libs/
│   ├── proto/                  # Shared gRPC contracts (.proto)
│   ├── dto/                    # Shared DTOs / validators
│   ├── common/                  # Guards, interceptors, decorators
│   └── types/                    # Shared TypeScript interfaces
├── infra/
│   ├── nginx/
│   ├── docker-compose.yml
│   └── scripts/                   # backup + deploy scripts
├── setup-devblog.sh
├── nx.json
├── pnpm-workspace.yaml
└── package.json
```

---

## Infrastructure

- Provisioned on a bare Linux VM (AWS EC2) — services installed from binaries rather than a package manager, for explicit version control
- Each microservice runs under its own `systemd` unit with automatic restart on failure
- PostgreSQL bound to `localhost` only (`pg_hba.conf`); no external access
- Nightly backup pipeline: dump → `gzip` → offsite copy → 7-day retention pruning
- Nginx terminates all inbound traffic and load-balances across gateway instances
- PgBouncer in front of PostgreSQL to sustain connection counts under high concurrency
- `main` / `dev` / `feature/*` branching model

---

## Getting Started

### Prerequisites

| Tool | Version | Notes |
|---|---|---|
| [Node.js](https://nodejs.org) | 20 LTS or newer | via [nvm](https://github.com/nvm-sh/nvm) recommended |
| [pnpm](https://pnpm.io) | 9+ | via `corepack enable` or `npm i -g pnpm` |
| [Git](https://git-scm.com) | any recent | — |
| [Docker](https://www.docker.com) + Docker Compose | any recent | for local Postgres / Mongo / Redis |
| Nx CLI | — | not required globally; invoked via `pnpm dlx` / `nx` from the workspace |

You have two ways to stand up the workspace: **clone the existing repo**, or **bootstrap a fresh one from scratch** using `setup-devblog.sh`, which scaffolds the entire Nx monorepo (all six backend services, the frontend, and shared libs) and installs every dependency in one pass.

### Option A — Clone the existing repository

```bash
git clone <repo-url>
cd devblog
pnpm install
```

### Option B — Bootstrap a fresh workspace with setup-devblog.sh

Use this if you're starting from an empty machine/folder and want the whole monorepo generated from scratch, exactly as this repo was built.

**1. Get the script into an empty parent folder** (e.g. `~/Projects`), then:

```bash
chmod +x setup-devblog.sh
./setup-devblog.sh Devblog
```

The argument (`Devblog`) is the folder name it will create/resume inside. The script is **idempotent** — safe to re-run if it stops partway through; it skips anything already generated.

**2. After it finishes**, a few steps are intentionally left manual (interactive prompts and secrets shouldn't be scripted):

```bash
cd Devblog/apps/frontend && npx shadcn@latest init   # interactive component setup
# then create .env files per service (see Environment Variables below)
# then write your .proto contracts inside libs/proto
git init && git add . && git commit -m "Initial Nx monorepo scaffold"
```

#### Which terminal to use, per OS

The script is a **bash script targeting a Linux/Ubuntu environment** — several of its steps (native module builds for `sharp`, `bcrypt`, `@parcel/watcher`, `grpc-tools`, etc.) compile against Linux binaries. Where you run it matters:

<table>
<tr><th width="18%">OS</th><th>Terminal to use</th></tr>
<tr>
<td><strong>Linux</strong><br/>(Ubuntu, Debian, Fedora, Arch, etc.)</td>
<td>

Your default terminal (GNOME Terminal, Konsole, Alacritty, etc.) running `bash` or `zsh`. No extra setup beyond Node.js + pnpm. This is the environment the script is written for.

</td>
</tr>
<tr>
<td><strong>macOS</strong></td>
<td>

**Terminal.app** or **iTerm2**, using the default `zsh` shell (bash also works). Install Node via [nvm](https://github.com/nvm-sh/nvm) or `brew install node`, then `corepack enable` for pnpm. macOS is Unix-based, so the script runs natively — no WSL-equivalent layer needed.

</td>
</tr>
<tr>
<td><strong>Windows</strong></td>
<td>

**Use WSL2 (Windows Subsystem for Linux) with an Ubuntu distro** — not PowerShell, not CMD, and not Git Bash. The script relies on bash-specific syntax (arrays, `local`, heredocs) and on native modules being compiled for a real Linux userland, which Git Bash cannot provide and PowerShell can't execute at all.

```powershell
# In PowerShell (as Administrator), one-time setup:
wsl --install -d Ubuntu
```

Restart, then open the **Ubuntu** app (this is your terminal from here on) and continue exactly as in the Linux instructions above — install Node.js/pnpm inside WSL2, place the script in a WSL2 filesystem path (e.g. `~/Projects`, *not* `/mnt/c/...`) for acceptable I/O performance, and run it there.

</td>
</tr>
</table>

---

## Environment Variables

Each service reads its own `.env` file (not committed — see `.gitignore`). A typical service needs:

```bash
# apps/<service>/.env
NODE_ENV=development
PORT=<service-port>

# PostgreSQL-backed services (auth, post, search, feed)
DATABASE_URL=postgresql://user:password@localhost:5432/devblog

# MongoDB-backed services (comment)
MONGODB_URI=mongodb://localhost:27017/devblog

# Redis (all services)
REDIS_URL=redis://localhost:6379

# Auth service only
JWT_SECRET=<generate-a-strong-random-value>
JWT_REFRESH_SECRET=<generate-a-strong-random-value>
```

Commit a `.env.example` per service with placeholder values so teammates know what's required without exposing real secrets.

---

## Roadmap

- [ ] Schema design — users, posts, tags, comments, likes, follows
- [ ] Indexing pass — `EXPLAIN ANALYZE` baseline, apply indexes, measure delta
- [ ] Complex query layer — trending, personalized feed, tag ranking
- [ ] Full-text search with bilingual relevance ranking
- [ ] Triggers — `updated_at`, likes sync, audit log emission
- [ ] Row-Level Security policies per role
- [ ] Redis integration — sessions, cache, rate limiting
- [ ] gRPC contracts across all services
- [ ] GraphQL Gateway with DataLoader
- [ ] Load testing at 10k+ concurrent connections

---

## License

This project is licensed under the [MIT License](LICENSE).

---

<div align="center">

Built as a self-directed systems design study — from schema to deployment.

</div>
