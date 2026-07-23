# DevBlog — Multi-User Publishing Platform
### Microservices-based Scalable Blogging System (Learning Project)

---

## 1. Project Overview

**DevBlog** ek multi-user blogging platform hai (Medium/Dev.to jaisa), jo teen roles support karta hai — **Author**, **Reader**, **Admin**. Iska primary goal simple CRUD app banana nahi hai — iska goal hai tumhe **real production-grade distributed system** design karna, build karna aur scale karna sikhana, taaki har cheez (schema design, indexing, caching, security, infra, microservices communication) tum khud experience karke seekho.

**Target scale (learning simulation):**
- 100k+ Monthly Active Users (MAU)
- 10,000–20,000 concurrent users
- Microservices architecture (monolith nahi)
- Full scalable frontend

**Goal:** Ek chhota sa project banake, real MNC-scale problems (jo actually production me aati hain) khud face karna aur solve karna.

---

## 2. High-Level Architecture

```
                        ┌─────────────┐
                        │   Frontend   │  (React/Next.js)
                        └──────┬───────┘
                               │  GraphQL (queries/mutations)
                        ┌──────▼───────┐
                        │    Nginx     │  (Reverse Proxy + Load Balancer)
                        └──────┬───────┘
                        ┌──────▼───────┐
                        │  GraphQL     │  (Standalone Gateway / BFF)
                        │  Gateway     │
                        └──────┬───────┘
        ┌──────────┬──────────┼──────────┬──────────┐
        │  gRPC     │  gRPC   │  gRPC    │  gRPC    │  gRPC
   ┌────▼───┐ ┌───▼────┐ ┌───▼─────┐┌───▼──────┐┌──▼───────────┐
   │  Auth  │ │  Post  │ │ Comment ││  Search  ││ Feed/Notif.  │
   │Service │ │Service │ │ Service ││ Service  ││   Service    │
   └────┬───┘ └───┬────┘ └───┬─────┘└───┬──────┘└──┬───────────┘
        │         │          │          │          │
   ┌────▼─────────▼──────────▼──────────▼──────────▼───┐
   │      PostgreSQL (per-service schema) + Redis        │
   └──────────────────────────────────────────────────────┘
```

**Communication pattern:**
- **Client ↔ Gateway:** GraphQL — frontend ek hi query me post + author + comments + likes fetch kar sakta hai (multiple REST round-trips ki jagah)
- **Gateway ↔ Services (Synchronous):** gRPC — Protocol Buffers based, HTTP/2, strongly-typed contracts, REST se fast. Har service ka apna `.proto` file hoga jisme uske RPC methods define honge
- **Service ↔ Service (Asynchronous):** Redis Pub/Sub / Event-driven — jab background me process ho sakta hai (e.g., naya post publish hua → feed cache invalidate karo, post delete hua → comment service cleanup kare)

---

## 3. Services — Detailed Breakdown

### 3.0 GraphQL Gateway (Standalone Service)
**Responsibility:** Single entry point for frontend — client-facing API layer (BFF pattern).

**Features:**
- GraphQL schema — Query, Mutation, (optionally Subscription for real-time notifications)
- Resolvers call downstream services via **gRPC**
- **DataLoader pattern** — N+1 query problem solve karna (e.g., 20 posts fetch karte waqt 20 alag author-lookup calls na ho, batch me ek call ho)
- Auth token verification (JWT) at gateway level before forwarding to services
- Query-level caching (Redis) — repeated queries ke liye
- Rate limiting per user at gateway level

**Learning outcome:** BFF pattern — frontend ki zaroorat ke hisaab se data shape karna, without over-fetching/under-fetching jo REST me hota hai. GraphQL + gRPC combo real production companies (e.g., Netflix-style architecture) me use hota hai.

---

### 3.1 Auth Service
**Responsibility:** User identity aur access control ka single source of truth.

**Features:**
- Signup / Login (email + password, hashed via bcrypt/argon2)
- JWT issue aur refresh token flow
- Role management (author / reader / admin)
- Session store in Redis (login state, multi-device support)
- Rate limiting on login attempts (brute-force protection)

**Learning outcome:** Distributed systems me har service ko independently token verify karna padta hai — is se JWT-based stateless auth ka real practical use samajh aayega.

---

### 3.2 Post Service (Core Domain)
**Responsibility:** Blog posts ka pura lifecycle.

**Features:**
- CRUD operations — create/edit/delete posts
- Draft / Published states, soft-delete (hard delete nahi, `deleted_at` column)
- Tags (many-to-many relation)
- Likes (denormalized count column, trigger se sync — expensive COUNT query avoid karne ke liye)
- Row Level Security (RLS) — author sirf apne posts (draft included) dekh/edit kar sake; reader sirf published; admin sab
- Database triggers (PostgreSQL):
  - `updated_at` auto-update on row change
  - Likes count denormalization sync
- Audit trail — har change (kya change hua, kisne kiya, kab) **MongoDB** me log hoga (Audit Logs collection) — trigger se event nikalke Mongo me likhwana, ya application layer se explicit log

**Schema design considerations:**
- Users (roles: author/reader/admin)
- Posts (draft/published/soft-deleted)
- Tags (many-to-many via join table)
- Comments (threaded/nested, self-referencing `parent_comment_id`)
- Likes (composite unique key: user_id + post_id)
- Follows (many-to-many, user follows user)

**Indexing strategy:**
- Pehle `EXPLAIN ANALYZE` se slow queries identify karo
- Phir appropriate indexes: unique index on email, index on `published_at`, full-text search (tsvector) index
- Before/after performance compare karo aur document karo

---

### 3.3 Comment Service
**Responsibility:** Threaded/nested comments, alag se scale hone wali entity.

**Database:** MongoDB — nested/threaded structure ke liye natural fit (tree-like data, flexible schema)

**Features:**
- Nested/self-referencing comment structure (parent_comment_id / tree via Mongoose)
- Post Service ko **gRPC call** se verify karna (post exist karta hai kya, published hai kya)
- Post delete hone par event-driven cleanup (async — Post Service se Redis Pub/Sub event aayega "post deleted", Comment Service apne comments soft-delete kar dega)

**Learning outcome:** Cross-service data consistency (eventual consistency) real me kaise handle hoti hai — bina distributed transaction ke.

---

### 3.4 Search Service
**Responsibility:** Full-text search — title + content dono me.

**Features:**
- PostgreSQL full-text search (tsvector/tsquery) se start karo
- Relevance-based ranking (exact match pehle, partial baad me)
- Hindi/English dono content support
- Future scope: Elasticsearch me migrate karke compare karo (optional, agar time ho)

**Learning outcome:** Search ko alag service rakhna real pattern hai kyunki iski read patterns aur scaling needs baaki services se alag hoti hain.

---

### 3.5 Feed / Notification Service
**Responsibility:** Personalized feed, trending posts, caching layer.

**Features:**
- Trending posts (last 7 days, most liked) — complex ranking query
- User feed — jinko follow karte ho unke posts (fan-out on read ya fan-out on write — dono approach try karke seekho)
- Tag-wise post count with ranking
- Redis caching:
  - Recent posts cache (5 min TTL)
  - Trending posts cache (1 hour TTL, background job se refresh)
  - Rate limiter (per-user API call limit)

**Learning outcome:** Cache invalidation strategy aur background workers (cron/BullMQ) ka real use.

---

## 4. Infrastructure & DevOps (Phase 1 Foundation)

Ye sab services deploy hone se pehle infra ready hona chahiye:

| Task | Detail |
|---|---|
| **Linux server setup** | AWS EC2 pe manual install (package manager nahi, binary download) — version control tumhare haath me |
| **systemd services** | Har microservice ka apna systemd unit file — auto-restart on crash/reboot |
| **PostgreSQL security** | `pg_hba.conf` config — sirf localhost accessible, bahar se access nahi |
| **Automated DB backup script** | Roz backup → gzip compress → remote copy → 7 din se purane backups auto-delete |
| **Nginx** | Reverse proxy + API Gateway — services directly expose nahi honge, sab Nginx ke peeche |
| **Git branching** | main / dev / feature branch strategy |
| **PgBouncer** | Connection pooling — 10-20k concurrent users pe raw Postgres connections crash kar dengi |
| **Load testing** | k6 ya Locust se concurrent users simulate karo, slowest queries identify karo |

---

## 5. Database Strategy

**Polyglot persistence (right DB for right service):**
- **PostgreSQL** — Auth Service, Post Service (structured relational data — users, posts, tags, likes, follows)
- **MongoDB** — Comment Service (nested/tree structure natural fit), Audit Logs collection (flexible schema for change history)
- Har service apna DB/schema khud own karta hai — koi dusri service directly uske DB me query nahi karti, sirf gRPC/events se baat hoti hai
- RLS apply hoga Postgres services ke andar apne data pe (Post Service)
- Cross-service access control gateway/token level pe (RLS ka replacement nahi, complement hai)

---

## 6. Frontend Considerations (Scale ke hisaab se)

- **Pagination / Infinite scroll** for feed — ek saath sab load nahi karna
- **Optimistic UI** — likes/comments turant UI me update, background me API call
- **SSR/ISR (Next.js)** — post pages ke liye, SEO + fast load
- **Client-side caching** — React Query/SWR se bar-bar API call avoid karna
- **Code splitting** — route-based lazy loading

---

## 7. Milestones → Service Mapping (Reference Table)

| Original Milestone | Ab kis service me |
|---|---|
| Schema design | Post Service (core), Auth Service (users) |
| Indexing strategy | Post Service |
| Complex queries (trending, feed) | Feed/Notification Service |
| Full-text search | Search Service |
| Database triggers | Post Service |
| Row Level Security | Post Service (own schema) |
| Redis integration | Auth Service (sessions), Feed Service (cache), Gateway (rate limit) |
| Deploy + performance test | All services + Nginx Gateway |

---

## 8. Tech Stack Summary

### Backend

| Category | Technology |
|---|---|
| Framework | NestJS |
| Monorepo | Nx (shared libs, proto files, DTOs across services) |
| Relational DB | PostgreSQL 15+ (Auth, Post services) |
| Document DB | MongoDB (Comment Service, Audit Logs) |
| Cache/Session/Pub-Sub | Redis 7+ |
| ORM (Postgres) | TypeORM |
| ODM (Mongo) | Mongoose |
| Inter-service comm. | gRPC (`@grpc/grpc-js`, `@grpc/proto-loader`, `@nestjs/microservices`) |
| Client-facing API | GraphQL — Apollo Server (`@nestjs/graphql`, `@nestjs/apollo`) |
| Validation | class-validator, class-transformer |
| Auth | bcrypt, `@nestjs/jwt`, passport-jwt, `@nestjs/passport` |
| Config | `@nestjs/config` |
| Scheduled tasks | `@nestjs/schedule` (cron-based — cache refresh, no message queue) |
| Security middleware | helmet, compression |
| Logging | nestjs-pino (or winston) |
| Health checks | `@nestjs/terminus` |
| Reverse Proxy / LB | Nginx |
| Connection Pooling | PgBouncer |
| Load Testing | k6 or Locust |
| OS | Linux (Ubuntu, systemd) |

### Frontend

| Category | Technology |
|---|---|
| Framework | Next.js |
| Styling | Tailwind CSS |
| UI Components | shadcn/ui |
| Animation | Framer Motion |
| GraphQL Client | Apollo Client |
| Global State | Redux Toolkit |
| Forms | React Hook Form + Zod |
| Icons | lucide-react |

**Note:** Message queue (BullMQ/RabbitMQ/Kafka) **intentionally use nahi kiya** — saara "async" kaam Redis Pub/Sub (event broadcast) aur `@nestjs/schedule` (cron jobs) se hoga.

---

## 9. Key Learning Outcomes (Why this project matters)

1. Monolith vs microservices — trade-offs practically samajhna
2. Sync vs async inter-service communication
3. Database schema design at scale (denormalization, triggers, RLS)
4. Caching strategy aur invalidation
5. Real infra setup (systemd, Nginx, backups) — sirf code nahi, poora system
6. Load testing aur performance bottleneck identification
7. Frontend scaling patterns (SSR, caching, optimistic UI)
8. GraphQL Gateway (BFF pattern) — schema design, DataLoader/N+1 problem solving
9. gRPC + Protobuf — strongly-typed inter-service contracts, versioning

---

*Next step: Docker-compose setup + folder structure, phir Auth Service se coding start.*
