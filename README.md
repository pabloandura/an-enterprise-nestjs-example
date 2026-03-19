# Enterprise NestJS E-Commerce Platform

A NestJS API built in response to an engineering challenge. The backend is the subject of this repository — the frontend and infrastructure exist only to give it real context.

## Challenge Compliance

The challenge required: NestJS + MongoDB + JWT, with Product and Order endpoints, file upload, pagination/sorting/filtering, and a Docker bonus.

**All requirements are met. Intentional divergences:**

| Area | Requirement | What was built | Why |
|---|---|---|---|
| Persistence | MongoDB only (`@nestjs/mongoose`) | MongoDB for Products & Orders; **PostgreSQL for Auth** | Auth needs relational integrity: `UNIQUE` on email, FK from `refresh_tokens → users`, transactional token rotation. `@nestjs/mongoose` is used exactly as required for the two data-heavy modules. |
| Auth | JWT strategy | JWT **+ refresh token rotation** | A bare access token with no rotation is insecure for a real API. The JWT guard itself is the auth strategy; refresh tokens extend it without replacing it. |
| Order "list of products" | Reference to products | **Embedded line-item snapshots** (`priceAtPurchase`, `name`, `sku`) | Price changes after an order is placed should not alter historical totals — standard e-commerce practice. |
| Product "picture" field | File upload | Stored as `imageUrl`; file written to disk or S3 | The upload is multipart (satisfies the requirement); the field name reflects what is actually persisted. |
| Roles | Not mentioned | ADMIN vs USER roles guard | Required to protect mutation and reporting endpoints in a realistic API. |
| Bonus | Dockerize | Docker + **AWS CloudFormation + ECS + frontend** | The bonus is covered; the extra scope demonstrates a production-ready delivery. |

## Repository Layout

```
an-enterprise-nestjs-example/
├── backend/                        ← Git submodule → github.com/pabloandura/backend-nestjs
├── frontend/                       ← Git submodule → github.com/pabloandura/frontend-react
├── infra/
│   ├── cloudformation/             ← CloudFormation stacks (deploy to AWS)
│   │   ├── 01-networking.yml       ← VPC, subnets, security groups
│   │   ├── 02-storage.yml          ← S3 bucket
│   │   ├── 03-databases.yml        ← RDS PostgreSQL + DocumentDB
│   │   ├── 04-compute.yml          ← ECR, ECS, ALB, IAM
│   │   └── deploy.sh               ← Deploys all stacks in order
│   └── db/
│       ├── postgres/01-init-schema.sql
│       └── mongo/01-init-indexes.js
├── docker-compose.dev.yml          ← Local development (hot-reload, local disk storage)
├── docker-compose.prod.yml         ← Production-ready (S3 storage driver)
├── .env.example                    ← All required env vars documented
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

## Infrastructure as Code (AWS)

The [`infra/cloudformation/`](infra/cloudformation/) directory contains four CloudFormation stacks that deploy the full AWS environment. They must be deployed in order because each stack exports values consumed by the next.

| Stack | File | What it creates |
|---|---|---|
| 1 — Networking | [`01-networking.yml`](infra/cloudformation/01-networking.yml) | VPC, 6 subnets across 2 AZs, IGW, NAT Gateway, 5 security groups |
| 2 — Storage | [`02-storage.yml`](infra/cloudformation/02-storage.yml) | S3 bucket for product image uploads |
| 3 — Databases | [`03-databases.yml`](infra/cloudformation/03-databases.yml) | RDS PostgreSQL 16 (auth) + DocumentDB (products/orders) |
| 4 — Compute | [`04-compute.yml`](infra/cloudformation/04-compute.yml) | ECR repos, IAM roles, ECS Fargate cluster, ALB, ECS services, GitHub OIDC role |

### Deploy

```bash
# First run: networking + storage + databases only
SKIP_COMPUTE=true \
POSTGRES_PASSWORD=<generated> \
DOCDB_PASSWORD=<generated> \
./infra/cloudformation/deploy.sh

# After pushing images and creating the Secrets Manager secret:
API_SECRET_ARN=arn:aws:secretsmanager:... \
POSTGRES_PASSWORD=<same> \
DOCDB_PASSWORD=<same> \
./infra/cloudformation/deploy.sh
```

The script prints all GitHub Actions secrets at the end so CI/CD can be wired up immediately.

### Architecture

```
Internet
    │
    ▼
ALB (public subnets, 2 AZs)
    ├── /api/*  ──► api ECS task (private subnet)
    │                  ├── RDS PostgreSQL (isolated subnet)
    │                  └── DocumentDB    (isolated subnet)
    └── /*      ──► frontend ECS task (private subnet, Nginx)
```

All ECS tasks run in private subnets with no public IP. Databases are in isolated subnets with no internet route. The API task role has scoped S3 access for file uploads — no static AWS credentials in the application.

---

## Production (local)

```bash
docker compose -f docker-compose.prod.yml up --build
```

The production compose sets `STORAGE_DRIVER=s3`. The API runs as a non-root user (`appuser`) in the final image stage. See [`backend/Dockerfile`](backend/Dockerfile).
