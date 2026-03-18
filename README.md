# Enterprise NestJS E-Commerce Platform

A production-grade e-commerce API demonstrating senior-level engineering practices: hexagonal architecture, polyglot persistence, JWT security with refresh token rotation, domain events, and containerised deployment targeting AWS.

## Repository Layout

```
an-enterprise-nestjs-example/
├── backend/               ← Git submodule → github.com/pabloandura/backend-nestjs
├── frontend/              ← Git submodule → github.com/pabloandura/frontend-react
├── infra/                 ← AWS deployment artefacts (ECS task defs, Terraform)
├── docker-compose.dev.yml ← Local development (hot-reload, local disk storage)
├── docker-compose.prod.yml← Production-ready (AWS/S3 storage driver)
├── .env.example           ← All required env vars documented
└── docs/initial-arch-idea.md ← Original acceptance criteria document
```

## Architecture Decision Records

### ADR-001 — Modular Monolith over Microservices
Each NestJS module is a bounded context (`Auth`, `Products`, `Orders`, `Common`). Modules communicate only through exported providers — never direct database cross-access. The structure makes future microservice extraction a clean cut because hexagonal boundaries are already in place. See [`backend/src/app.module.ts`](backend/src/app.module.ts).

### ADR-002 — Hexagonal Architecture per Module
Every feature module is layered as `domain/ → application/ → infrastructure/`:

- **Domain**: plain TypeScript classes, zero framework imports
- **Application**: use-cases injecting port interfaces via DI tokens
- **Infrastructure**: NestJS controllers, Mongoose/TypeORM adapters implementing those ports

Example port/adapter pair: [`backend/src/modules/products/domain/ports/product.repository.port.ts`](backend/src/modules/products/domain/ports/product.repository.port.ts) (port) and [`backend/src/modules/products/infrastructure/persistence/product.mongoose-repository.ts`](backend/src/modules/products/infrastructure/persistence/product.mongoose-repository.ts) (adapter).

### ADR-003 — Polyglot Persistence
| Store | Module | Reason |
|---|---|---|
| **PostgreSQL** | Auth | Relational integrity: `UNIQUE` on email, FK from refresh_tokens → users, role `ENUM`, transactional token rotation |
| **MongoDB** | Products, Orders | Flexible document model, embedded line-item snapshots, aggregation pipelines for reporting |

Init scripts: [`infra/db/postgres/01-init-schema.sql`](infra/db/postgres/01-init-schema.sql) and [`infra/db/mongo/01-init-indexes.js`](infra/db/mongo/01-init-indexes.js).

### ADR-004 — Domain Events + CQRS-Lite
`OrderCreatedEvent` and `OrderUpdatedEvent` are emitted via `EventEmitter2` so consumers (logging, analytics, notifications) can subscribe without coupling to the `OrderModule`. Reporting endpoints use MongoDB aggregation pipelines as an isolated read path. See [`backend/src/modules/orders/domain/events/`](backend/src/modules/orders/domain/events/).

### ADR-005 — Full NestJS Pipeline Exploitation
The full request lifecycle is wired globally:

```
Middleware → Guard → Interceptor → Pipe → Handler → Interceptor (response) → Filter (error)
```

| Layer | Implementation | File |
|---|---|---|
| Middleware | Correlation ID injection | `backend/src/common/middleware/correlation-id.middleware.ts` |
| Guard | JwtAuthGuard + RolesGuard | `backend/src/modules/auth/infrastructure/guards/` |
| Interceptor | Response envelope `{ success, data, meta?, correlationId }` | `backend/src/common/interceptors/response-envelope.interceptor.ts` |
| Pipe | ValidationPipe (global), ParseMongoIdPipe | `backend/src/common/pipes/parse-mongo-id.pipe.ts` |
| Filter | GlobalExceptionFilter — sanitised errors in production | `backend/src/common/filters/global-exception.filter.ts` |

---

## Quick Start (Development)

```bash
# 1. Clone with submodules
git clone --recurse-submodules https://github.com/pabloandura/an-enterprise-nestjs-example.git
cd an-enterprise-nestjs-example

# 2. Copy env
cp .env.example .env          # fill in JWT_SECRET at minimum

# 3. Start everything
docker compose -f docker-compose.dev.yml up --build

# API  → http://localhost:3000
# UI   → http://localhost:8080
# UI proxies /api/* → API automatically (Vite dev proxy)
```

## Services

| Service | Image | Port | Notes |
|---|---|---|---|
| `api` | `backend/Dockerfile` (target: development) | `3000` | Hot-reload via `ts-node-dev` |
| `frontend` | `frontend/Dockerfile` (target: development) | `8080` | Vite dev server with `/api` proxy |
| `mongo` | `mongo:7` | `27017` | Named volume `mongo_data_dev`, init indexes on first start |
| `postgres` | `postgres:16-alpine` | `5432` | Named volume `postgres_data_dev`, init schema on first start |

## Smoke Test

```bash
# Health
curl http://localhost:3000/health

# Register + login
curl -s -X POST http://localhost:3000/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"Alice","email":"alice@example.com","password":"secret123"}' | jq

TOKEN=$(curl -s -X POST http://localhost:3000/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"secret123"}' | jq -r '.data.accessToken')

# Create product (JWT required)
curl -s -X POST http://localhost:3000/products \
  -H "Authorization: Bearer $TOKEN" \
  -F 'name=Widget' -F 'sku=WGT-001' -F 'price=29.99' | jq

# List products (paginated)
curl -s "http://localhost:3000/products?page=1&limit=5" -H "Authorization: Bearer $TOKEN" | jq

# Create order
curl -s -X POST http://localhost:3000/orders \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"clientName":"Bob","items":[{"productId":"<id>","quantity":3}]}' | jq

# Reports
curl -s http://localhost:3000/orders/reports/total-last-month -H "Authorization: Bearer $TOKEN" | jq
curl -s http://localhost:3000/orders/reports/highest -H "Authorization: Bearer $TOKEN" | jq
```

## Environment Variables

See [`.env.example`](.env.example) — no secrets have default values. Required variables:

| Variable | Example | Purpose |
|---|---|---|
| `JWT_SECRET` | _(generate with `openssl rand -hex 32`)_ | Signs access tokens |
| `JWT_ACCESS_EXPIRES_IN` | `15m` | Short-lived access token TTL |
| `JWT_REFRESH_EXPIRES_IN` | `7d` | Long-lived refresh token TTL |
| `POSTGRES_*` | see .env.example | PostgreSQL connection |
| `MONGO_URI` | `mongodb://mongo:27017/ecommerce` | MongoDB connection |
| `STORAGE_DRIVER` | `local` / `s3` | Switches between `LocalStorageAdapter` and `S3StorageAdapter` |

## Production

```bash
docker compose -f docker-compose.prod.yml up --build
```

The production compose sets `STORAGE_DRIVER=s3`. The API runs as a non-root user (`appuser`) in the final image stage. See [`backend/Dockerfile`](backend/Dockerfile).
