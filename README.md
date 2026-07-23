<div align="center">

# DevBlog

**A distributed, multi-tenant publishing platform engineered for high-concurrency workloads.**

Microservices architecture · GraphQL BFF · gRPC · Polyglot persistence

<p align="center">
<a href="#"><img src="https://img.shields.io/badge/NestJS-E0234E?style=flat-square&logo=nestjs&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/Next.js-000000?style=flat-square&logo=nextdotjs&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/pnpm-F69220?style=flat-square&logo=pnpm&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/PostgreSQL-4169E1?style=flat-square&logo=postgresql&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/MongoDB-47A248?style=flat-square&logo=mongodb&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/Redis-DC382D?style=flat-square&logo=redis&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/GraphQL-E10098?style=flat-square&logo=graphql&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/gRPC-4285F4?style=flat-square&logo=googlecloud&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/Nx_Monorepo-143055?style=flat-square&logo=nx&logoColor=white" /></a>
<a href="#"><img src="https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white" /></a>
<a href="#license"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" /></a>
</p>

[Overview](#overview) · [Architecture](#architecture) · [Design Decisions](#design-decisions--trade-offs) · [Data Model](#data-model) · [API Contracts](#api-contracts) · [Caching](#caching-strategy) · [Services](#services) · [Tech Stack](#tech-stack) · [Reliability](#reliability--scaling) · [Security](#security) · [Observability](#observability) · [Testing](#testing-strategy) · [Getting Started](#getting-started) · [Local Dev](#local-development) · [FAQ](#faq) · [Roadmap](#roadmap)

</div>

---

## Overview

DevBlog is a multi-user publishing platform — comparable in scope to Medium or Dev.to — designed and built as a **distributed system rather than a monolith**. It supports three roles (**Author**, **Reader**, **Admin**) and is architected against a target load profile of **100k+ monthly active users** and **10k–20k concurrent connections**.

### Why this exists

Most portfolio "blog" projects are a single Express/Next app with one Postgres database — enough to demonstrate CRUD, but not enough to demonstrate how systems actually break and get designed around at scale. DevBlog is deliberately over-engineered relative to what a blog needs, because the point isn't the blog — it's using the blog as a vehicle to make the same decisions a backend/platform engineer makes on a real production system:

- How do you split a monolith into services **without** turning every read into five network calls?
- When do you reach for a second database instead of forcing everything into one schema?
- How do you keep two services' data consistent **without** a message broker, and what do you give up by doing that?
- Where does authorization actually belong — application code, or the database itself?
- What breaks first at 10,000 concurrent connections, and how do you see it before it happens?

Every section below tries to answer one of those questions concretely, with the actual trade-off, not just the final choice.

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

Why a **GraphQL gateway in front of gRPC services**, rather than exposing GraphQL or REST directly on each service? Two reasons: first, the frontend needs client-shaped, nested data (a post with its author, tags, and top comments) in one round trip — that's GraphQL's job. Second, internally, services talk to each other far more often than the client talks to any single service, and those internal calls need low latency and strict typed contracts — that's gRPC's job. Using one protocol for both would force a bad compromise on one side.

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

The client gets its response the moment the Post Service commits the write — it does **not** wait for the Feed Service to react. Feed invalidation happens asynchronously off the Pub/Sub event. This is a deliberate consistency trade-off: the author sees their post as published instantly, but it may take a few hundred milliseconds to appear in someone else's trending feed. That's acceptable for a feed; it would not be acceptable for, say, a balance transfer.

### Request lifecycle — reading a personalized feed (cache-aside)

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant G as GraphQL Gateway
    participant F as Feed Service
    participant R as Redis
    participant DB as PostgreSQL

    C->>G: query feed(userId)
    G->>F: gRPC GetFeed(userId)
    F->>R: GET feed:user:{userId}
    alt cache hit
        R-->>F: cached feed (JSON)
    else cache miss
        F->>DB: query follow graph + recent posts + engagement
        DB-->>F: rows
        F->>R: SET feed:user:{userId} (TTL 5m)
    end
    F-->>G: feed payload
    G-->>C: GraphQL response
```

### Communication patterns

| Interaction | Path | Protocol | Rationale |
|---|---|---|---|
| Client → API | Frontend → Gateway | GraphQL | Single round-trip for nested, client-shaped data |
| API → Services | Gateway → Microservices | gRPC / Protobuf | Typed contracts, binary payloads, HTTP/2 multiplexing |
| Service → Service | Post → Comment, Post → Feed | Redis Pub/Sub | Decoupled, eventual-consistency side effects |
| Scheduled work | Feed Service | `@nestjs/schedule` (cron) | Deterministic cache refresh without a broker |

---

## Design Decisions & Trade-offs

Short "ADR-style" notes on the choices that shape this system — what was picked, what the alternative was, and why the alternative lost.

**Database-per-service instead of one shared database**
Alternative: one Postgres database, all services connect directly. Rejected because it silently re-couples services at the schema level — any service could depend on another's internal columns, and a migration in one service could break another. Database-per-service forces all cross-service reads through a typed gRPC contract, which is slower to write but keeps the failure and deployment blast radius contained to one service.

**Redis Pub/Sub instead of a message broker (Kafka/RabbitMQ/BullMQ)**
Alternative: introduce Kafka or RabbitMQ for `post.published` / `post.deleted` events. Rejected for this system's actual fan-out (a handful of consumers, no replay/ordering requirements, no need for consumer groups or exactly-once delivery). Redis Pub/Sub is fire-and-forget — if the Feed Service is down when an event fires, that event is lost, and the trending cache simply falls back to its normal TTL-based refresh on the next cron tick. That's an acceptable failure mode here; it would not be if these were financial transactions.

**MongoDB for comments instead of Postgres**
Alternative: model comments as a self-referencing `parent_id` table in Postgres. Rejected because arbitrarily deep reply threads require recursive CTEs that get expensive to paginate correctly, and comment trees are naturally schema-flexible (attachments, reactions, edit history can vary per comment). A document store maps directly onto that shape without fighting the relational model.

**Row-Level Security instead of application-layer authorization checks**
Alternative: check `post.authorId === currentUser.id` in every service method before returning data. Rejected as the sole mechanism because it's easy to forget in a new endpoint — one missed check leaks drafts. RLS policies live in Postgres itself, so even a query written incorrectly in application code still can't return rows the current role isn't allowed to see. Application-layer checks are still used for UX-level responses (403 vs. empty result), but the database is the actual enforcement boundary.

**gRPC instead of REST for service-to-service calls**
Alternative: internal REST + JSON between services. Rejected because REST/JSON gives up two things this system needs internally: a strict, versionable contract (protobuf) that fails to compile rather than fails at runtime when a field is renamed, and binary payloads over HTTP/2 multiplexed connections, which matter once internal call volume is an order of magnitude higher than external request volume.

**No ORM-level cross-service joins**
Every "join" across a service boundary (e.g., "show me this comment's post title") is a gRPC call, not a database join — even though, physically, nothing stops two services' databases from living on the same Postgres instance in early stages. This is intentional: it keeps the code honest about where the network boundary actually is, so splitting services onto separate infrastructure later is a deployment change, not a rewrite.

---

## Data Model

Simplified core schema (PostgreSQL side — Auth/Post/Search/Feed). Comment documents in MongoDB are described separately below.

```mermaid
erDiagram
    USERS ||--o{ POSTS : authors
    USERS ||--o{ SESSIONS : has
    USERS ||--o{ FOLLOWS : follows
    POSTS ||--o{ POST_TAGS : tagged_with
    TAGS ||--o{ POST_TAGS : applied_to
    POSTS ||--o{ LIKES : receives
    USERS ||--o{ LIKES : gives
    POSTS ||--o{ AUDIT_LOG : tracked_by

    USERS {
        uuid id PK
        text email
        text password_hash
        text role "author | reader | admin"
        timestamptz created_at
    }
    POSTS {
        uuid id PK
        uuid author_id FK
        text title
        text body
        text status "draft | published | deleted"
        int like_count "denormalized"
        tsvector search_vector
        timestamptz published_at
    }
    TAGS {
        uuid id PK
        text name
    }
    POST_TAGS {
        uuid post_id FK
        uuid tag_id FK
    }
    LIKES {
        uuid user_id FK
        uuid post_id FK
        timestamptz created_at
    }
    FOLLOWS {
        uuid follower_id FK
        uuid followee_id FK
    }
    SESSIONS {
        uuid id PK
        uuid user_id FK
        text refresh_token_hash
        timestamptz expires_at
    }
    AUDIT_LOG {
        uuid id PK
        uuid post_id FK
        text action
        jsonb diff
        timestamptz created_at
    }
```

**Comment documents (MongoDB)** — modeled as a tree rather than a flat table so an arbitrarily deep reply chain is one document read, not a recursive query:

```json
{
  "_id": "ObjectId",
  "postId": "uuid-of-post-in-postgres",
  "authorId": "uuid-of-user",
  "body": "text",
  "createdAt": "ISODate",
  "replies": [
    {
      "_id": "ObjectId",
      "authorId": "uuid-of-user",
      "body": "text",
      "createdAt": "ISODate",
      "replies": []
    }
  ]
}
```

`postId` is validated against the Post Service via gRPC at write time rather than a database-level foreign key — because there is no database-level foreign key possible across a Postgres/MongoDB boundary. This is exactly the kind of constraint that database-per-service gives up, and gRPC validation is how it's paid back.

---

## API Contracts

Contracts are the actual source of truth for what crosses a service boundary — not documentation, the `.proto` and GraphQL schema files themselves. A sample of each:

**gRPC contract** (`libs/proto/post.proto`) — what the Gateway and Post Service agree on:

```protobuf
syntax = "proto3";

package post;

service PostService {
  rpc GetPost (GetPostRequest) returns (Post);
  rpc PublishPost (PublishPostRequest) returns (Post);
  rpc DeletePost (DeletePostRequest) returns (DeletePostResponse);
}

message Post {
  string id = 1;
  string authorId = 2;
  string title = 3;
  string body = 4;
  string status = 5;       // draft | published | deleted
  int32 likeCount = 6;
  repeated string tags = 7;
  string publishedAt = 8;  // ISO 8601, empty if still a draft
}

message GetPostRequest { string id = 1; }
message PublishPostRequest { string id = 1; string authorId = 2; }
message DeletePostRequest { string id = 1; string authorId = 2; }
message DeletePostResponse { bool success = 1; }
```

Because this is compiled (via `ts-proto` / `grpc-tools`, already wired into the setup script), a field rename on one side is a **compile error** on both sides — not a runtime surprise discovered in production.

**GraphQL schema** (gateway-facing) — what the frontend actually queries:

```graphql
type Post {
  id: ID!
  title: String!
  body: String!
  status: PostStatus!
  likeCount: Int!
  tags: [String!]!
  author: User!          # resolved via DataLoader, batched across the whole query
  comments: [Comment!]!  # resolved via a gRPC call to Comment Service
  publishedAt: String
}

enum PostStatus { DRAFT PUBLISHED DELETED }

type Query {
  post(id: ID!): Post
  feed(userId: ID!): [Post!]!
  searchPosts(query: String!): [Post!]!
}

type Mutation {
  publishPost(input: PublishPostInput!): Post!
  deletePost(id: ID!): Boolean!
}

input PublishPostInput {
  title: String!
  body: String!
  tags: [String!]
}
```

The gateway's `author` and `comments` resolvers are exactly where DataLoader batching matters: without it, rendering a feed of 20 posts would trigger 20 separate `GetUser` calls and 20 separate `GetComments` calls. With it, those collapse into one batched call per field, per request tick.



| Data | Store | TTL | Invalidation |
|---|---|---|---|
| Session / refresh token | Redis | token lifetime | explicit delete on logout/rotation |
| Personalized feed | Redis | 5 minutes | passive TTL expiry + `post.published` event (see sequence diagram above) |
| Trending list | Redis | 1 hour | cron refresh (`@nestjs/schedule`) recomputes from a 7-day rolling window |
| Post like count | Postgres (denormalized column) | — | kept in sync via a database trigger on the `likes` table, avoiding `COUNT()` on every read |
| Rate-limit counters | Redis | sliding window | natural expiry |

The general rule followed throughout: **cache what's expensive to compute and tolerant of being briefly stale** (trending, personalized feeds), and **never cache what must be correct on the next read** (auth state, like counts a user just changed) — those are read from source or kept in sync structurally (the trigger), not cached at all.

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

## Reliability & Scaling

- **Connection pooling**: PgBouncer sits in front of PostgreSQL in transaction-pooling mode, so each service instance doesn't need its own large connection pool — this is what makes 10k+ concurrent connections survivable without exhausting Postgres's native connection limit.
- **Stateless services**: every backend service is stateless at the process level (session state lives in Redis, not memory), so horizontal scaling is just running more instances behind Nginx — no sticky sessions required.
- **Health checks**: `@nestjs/terminus` exposes liveness/readiness endpoints per service, so an orchestrator (or `systemd` + a supervisor script, in the current bare-VM deployment) can restart a service that's up but not actually healthy (e.g., DB connection lost).
- **Graceful degradation on event loss**: because Redis Pub/Sub delivery isn't guaranteed, every event-driven side effect (cache invalidation, cross-service cleanup) also has a fallback path — a TTL expiry or a scheduled reconciliation job — so a missed event degrades freshness, not correctness.
- **Rate limiting at the edge**: enforced in the GraphQL Gateway before a request ever reaches a service, so a single noisy client can't starve backend capacity for everyone else.

### Failure modes — what happens when a dependency goes down

| Dependency fails | Immediate effect | Fallback / recovery |
|---|---|---|
| Redis (cache) | Feed/trending reads fall through to Postgres on every request | Slower reads, not broken reads — TTL-based design means "no cache" is a valid, if slow, state |
| Redis (Pub/Sub) | `post.published` / `post.deleted` events are silently dropped | Feed cache staleness self-heals on the next TTL expiry or cron tick — no manual intervention needed |
| Comment Service | Post pages render without the comment thread (gateway catches the gRPC error, returns `comments: []`) | Post/like/search functionality is unaffected — the outage is isolated to one field |
| Post Service | Feed, search, and comment validation all degrade (they all call Post Service for canonical post data) | This is the one true single point of failure in the current design — see Roadmap for planned mitigation |
| PostgreSQL | Every Postgres-backed service (Auth, Post, Search, Feed) fails health checks and stops accepting traffic | `systemd` restarts the affected services once the DB is reachable again; PgBouncer queues rather than instantly rejecting short blips |
| Nginx | Entire platform unreachable | Single point of failure by design at this stage — production hardening would add a second Nginx instance behind a floating IP / DNS failover |

Being explicit about the last two rows matters as much as the resilience features above it — a design document that only lists what's handled, without naming what still isn't, isn't telling the whole truth about the system.

### Capacity planning — back-of-envelope math

Rough numbers used to size the data layer for the ~10k–20k concurrent connection target (not a benchmark result — a sizing exercise done before writing any service code):

- **Postgres connections**: with PgBouncer in transaction-pooling mode, a pool of ~100 real Postgres connections can serve on the order of several thousand concurrent client requests, since a connection is only checked out for the duration of a single transaction, not the life of a client session. Sizing the pool is a function of average transaction time, not concurrent users.
- **Redis**: a single Redis instance handles this workload comfortably on ops/sec alone (cache reads dominate, and Redis single-threaded throughput is well beyond what this traffic shape needs) — the actual constraint here is memory for cached feed payloads, not CPU.
- **Gateway instances**: since the gateway is stateless, capacity is simply `target_concurrency / connections_per_instance`, scaled horizontally behind Nginx — there's no architectural ceiling here, only a cost one.



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

## Security

- **Passwords**: hashed with `bcrypt` (never stored or logged in plaintext); cost factor tuned to stay under ~200ms on the target hardware so login latency doesn't degrade under load.
- **Tokens**: short-lived access JWTs (minutes, not days) paired with a longer-lived refresh token whose hash — not the raw token — is what's stored in Postgres/Redis, so a database leak alone can't be used to mint new sessions.
- **Transport**: Nginx terminates TLS at the edge; nothing internal (gateway ↔ services) is expected to cross the public internet, but internal traffic is still assumed hostile enough to require the JWT verification step at the gateway rather than trusting network location alone.
- **Authorization boundary**: as covered in [Design Decisions](#design-decisions--trade-offs), the database (Row-Level Security) is the actual enforcement point for "can this user see this draft," not application code — application code adds UX-friendly error messages on top of that, it isn't the only gate.
- **Input validation**: every DTO crossing a gateway → service boundary is validated with `class-validator` before it touches business logic, so malformed input fails at the edge of a service, not three layers deep inside a query.
- **Secrets**: never committed — see [Environment Variables](#environment-variables) and the `.gitignore` entries the setup script enforces (`.env`, `.env.*`, with `.env.example` explicitly allowed through).
- **Rate limiting**: applied per IP/account at both the Auth Service (login attempts) and the GraphQL Gateway (general request volume), so credential stuffing and simple denial-of-service attempts are throttled before they reach a database.

---

## Observability

- **Structured logging**: every service logs JSON (via `nestjs-pino`), not freeform strings — so logs are queryable rather than grep-dependent. A representative log line:

  ```json
  {"level":30,"time":1732000000000,"service":"post-service","reqId":"a1b2c3","userId":"u_9f2e","msg":"post.published","postId":"p_772a","durationMs":42}
  ```

- **Correlation across services**: a request ID generated at the Gateway is propagated through every downstream gRPC call and included in every log line it produces, so a single slow or failing user request can be traced across service boundaries by grepping one `reqId` — without a distributed tracing system in place yet (see Roadmap).
- **Health endpoints**: `@nestjs/terminus` exposes `/health` per service, checking its own DB/Redis connectivity — this is what a supervisor (or future orchestrator) polls to decide whether to restart an instance.
- **What's intentionally not built yet**: metrics dashboards (Prometheus/Grafana) and distributed tracing (OpenTelemetry) are known gaps, not oversights — structured logs and health checks cover this system's current scale; the Roadmap below is where they'd be added first if traffic grew past what log-grepping can reasonably answer.

---

## Testing Strategy

| Layer | Approach |
|---|---|
| Unit tests | Per-service, colocated with source (`*.spec.ts`), covering business logic in isolation — DB and gRPC calls mocked |
| Integration tests | Per-service, against a real Postgres/Mongo/Redis (via Docker Compose in CI), covering the service's own database layer end-to-end |
| Contract tests | gRPC calls between services are exercised against the compiled `.proto` types directly — a contract change that breaks a consumer fails at compile time (see [API Contracts](#api-contracts)), which covers most of what a separate contract-testing tool would otherwise catch |
| E2E tests | Generated per-app by Nx (`apps/<service>-e2e`) — smoke-level coverage of the running service's external surface |
| Load testing | k6 / Locust scripts (planned) targeting the GraphQL Gateway, ramping toward the 10k–20k concurrent connection design target to find the actual bottleneck rather than assume one |

The deliberate choice here is that **contract correctness between services leans on the compiled proto types**, not a separate contract-testing layer (like Pact) — for a system this size, one more moving part in CI wasn't worth it when the compiler already catches the same class of break.

---

## Local Development

The fastest inner loop is Docker Compose for infra + `nx serve` for the service you're actively working on — you don't need every service running to work on one of them.

```bash
# Bring up Postgres, MongoDB, and Redis
docker compose -f infra/docker-compose.yml up -d

# Run only the service(s) you're working on
nx serve post-service
nx serve gateway      # in another terminal, if you need the full request path

# Run the frontend against the gateway
nx serve frontend
```

A minimal `infra/docker-compose.yml` for local dependencies looks like:

```yaml
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: devblog
      POSTGRES_PASSWORD: devblog
      POSTGRES_DB: devblog
    ports: ["5432:5432"]
    volumes: ["pgdata:/var/lib/postgresql/data"]

  mongo:
    image: mongo:7
    ports: ["27017:27017"]
    volumes: ["mongodata:/data/db"]

  redis:
    image: redis:7
    ports: ["6379:6379"]

volumes:
  pgdata:
  mongodata:
```

Point each service's `.env` at these (`localhost:5432`, `localhost:27017`, `localhost:6379`) and you have a full local stack without touching the production infrastructure described above.



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
- [ ] Distributed tracing (OpenTelemetry) to replace `reqId`-grepping across logs
- [ ] Metrics + dashboards (Prometheus / Grafana)
- [ ] Redundant Nginx / floating-IP failover to remove the single point of failure at the edge
- [ ] Post Service read-replica strategy, to reduce how much of the system depends on one service being up

---

## FAQ

**Why not just use one Postgres database with well-organized schemas instead of splitting into services at all?**
That would genuinely be simpler, and for a lot of real products it's the right call. This project splits into services specifically *because* the goal is to practice the decisions that come with distribution — service boundaries, contract design, eventual consistency — not because a blog's actual traffic requires it.

**Isn't Redis Pub/Sub a single point of failure for cross-service events?**
Yes, and that's addressed directly in [Failure Modes](#failure-modes--what-happens-when-a-dependency-goes-down): every event-driven side effect has a non-event fallback (TTL expiry or cron reconciliation), so losing an event degrades freshness, not correctness.

**Why gRPC instead of just calling REST endpoints between services?**
Covered in [Design Decisions](#design-decisions--trade-offs) — typed, compiled contracts and HTTP/2 multiplexing matter more once internal call volume exceeds external request volume, which it does here (one client request fans out into several service calls).

**What's the actual single point of failure in this design?**
Named explicitly rather than glossed over: the Post Service (Feed, Search, and Comment validation all depend on it) and the single Nginx instance at the edge. Both are called out in the Failure Modes table above, along with what production hardening for each would look like.

**Is this over-engineered for what it does?**
Yes, deliberately — see [Why this exists](#why-this-exists).



This project is licensed under the [MIT License](LICENSE).

---

<div align="center">

Built as a self-directed systems design study — from schema to deployment.

</div>
