# $0 Cloud Stack — Implementation Plan

> **Target architecture:** Cloudflare Pages + optional Cloudflare Worker edge gateway + Cloudflare R2 + Google Cloud Run + Neon Postgres.
>
> **Primary constraint:** steady-state infrastructure spend must remain **$0/month** while the workload remains within the providers' free-tier limits.
>
> **Verified against provider pricing/docs:** 2026-08-15. Free-tier limits can change; re-check them before production deployment.

---

## 1. Objective

Build a reusable, production-shaped cloud application platform that can host small portfolio projects, APIs, dashboards, scrapers triggered on demand, and lightweight data applications without maintaining an always-on server.

The completed platform must:

1. Serve a static frontend globally through Cloudflare.
2. Run Python/container workloads on Google Cloud Run and scale to zero when idle.
3. Persist relational application data in Neon PostgreSQL.
4. Store files, datasets, images, model artifacts, exports, and backups in Cloudflare R2.
5. Keep credentials out of source control.
6. Support local development with the same application interfaces used in production.
7. Deploy automatically from GitHub.
8. Include health checks, structured logs, tests, migrations, backup/export procedures, and cost/usage checks.
9. Fail safely when a free-tier boundary is approached instead of silently scaling into an expensive configuration.
10. Be reusable as a template for future projects.

---

## 2. Current $0 operating envelope

These limits are the design envelope, not targets to consume fully.

| Service | Free operating envelope used by this plan | Design implication |
|---|---:|---|
| Cloudflare Pages | Static asset delivery is free; Free plan currently allows 500 deploys/month | Build frontend as static assets whenever possible |
| Cloudflare Workers | 100,000 requests/day on Free; Pages Functions share that request allowance | Keep edge code tiny and optional; do not move heavy Python work here |
| Cloudflare R2 Standard | 10 GB-month storage, 1M Class A operations/month, 10M Class B operations/month, Internet egress free | Store large/static objects here instead of Cloud Run filesystem or Postgres |
| Cloud Run request-based billing | 2M requests/month, 180k vCPU-seconds/month, 360k GiB-seconds/month; 1 GiB outbound transfer from North America/month under Google Cloud Free Tier | `min-instances=0`, bounded memory/CPU, low timeout, avoid serving large files through Cloud Run |
| Neon Free | $0; currently 100 CU-hours/project/month and 0.5 GB storage/project | Keep relational data compact; put blobs/files in R2 |

### Important billing reality

- Google Cloud requires a **billing account** even when using Free Tier resources.
- R2 requires enabling an R2 subscription/checkout flow even though included monthly usage can make the bill $0.
- Therefore this architecture is **capable of a $0 bill but cannot mathematically guarantee $0 merely because a service has a free tier**.
- The implementation must use explicit quotas, scaling limits, alerts, usage dashboards, and application-level controls.

---

## 3. Reference architecture

```text
                         ┌─────────────────────────┐
                         │        GitHub           │
                         │ source + Actions CI/CD  │
                         └────────────┬────────────┘
                                      │
                          deploy      │
                    ┌─────────────────┴──────────────────┐
                    │                                    │
                    ▼                                    ▼
          ┌──────────────────┐                 ┌──────────────────┐
          │ Cloudflare Pages │                 │ Google Cloud Run │
          │ static frontend  │                 │ container API    │
          └─────────┬────────┘                 └─────────┬────────┘
                    │                                    │
                    │ HTTPS                              │
                    └────────────────┬───────────────────┘
                                     │
                                     ▼
                              Application API
                                │          │
                      SQL       │          │ S3 API
                                ▼          ▼
                       ┌─────────────┐ ┌─────────────┐
                       │    Neon     │ │     R2      │
                       │ PostgreSQL  │ │ object data │
                       └─────────────┘ └─────────────┘
```

### Optional edge gateway

Add a Cloudflare Worker only when one of these is required:

- same-origin `/api/*` routing,
- lightweight request validation,
- coarse abuse controls,
- signed/controlled access to R2,
- header normalization,
- hiding the raw Cloud Run origin from normal clients.

Do **not** use the Worker for CPU-heavy transformations or Python workloads. The Worker Free plan has a small per-request CPU budget.

---

## 4. Technology choices

### Frontend

Default:

- Vite
- React + TypeScript, or plain TypeScript if UI complexity is low
- static build output
- Cloudflare Pages deployment

Rules:

- no always-on Node server for the frontend;
- use browser-side rendering unless SSR is genuinely required;
- aggressively cache immutable assets;
- never proxy large R2 downloads through Cloud Run.

### Backend

Default:

- Python 3.12+
- FastAPI
- Uvicorn
- SQLAlchemy 2.x
- Alembic
- `psycopg` PostgreSQL driver
- `boto3` or an S3-compatible client for R2
- Pydantic settings for configuration
- Docker

Backend must be stateless. Any data that must survive a container restart belongs in Neon or R2.

### Database

- Neon PostgreSQL
- SSL required
- pooled database connection string for runtime
- direct/unpooled connection string only for migrations if necessary
- Alembic owns schema migrations

### Object storage

- R2 Standard storage class only while staying inside the referenced free tier
- private bucket by default
- S3-compatible API
- presigned URLs for upload/download when practical

---

## 5. Repository layout

Create a monorepo so one project contains app code, infrastructure scripts, tests, and documentation.

```text
zero-cloud-stack/
├── .github/
│   └── workflows/
│       ├── ci.yml
│       ├── deploy-api.yml
│       └── deploy-web.yml
├── apps/
│   ├── api/
│   │   ├── app/
│   │   │   ├── main.py
│   │   │   ├── config.py
│   │   │   ├── db.py
│   │   │   ├── models/
│   │   │   ├── schemas/
│   │   │   ├── routes/
│   │   │   ├── services/
│   │   │   └── storage.py
│   │   ├── migrations/
│   │   ├── tests/
│   │   ├── alembic.ini
│   │   ├── Dockerfile
│   │   ├── pyproject.toml
│   │   └── requirements.lock
│   └── web/
│       ├── src/
│       ├── public/
│       ├── package.json
│       ├── package-lock.json
│       └── vite.config.ts
├── edge/
│   └── worker/                 # optional
│       ├── src/index.ts
│       ├── wrangler.toml
│       └── package.json
├── infra/
│   ├── gcp/
│   │   ├── bootstrap.sh
│   │   └── deploy-cloud-run.sh
│   ├── cloudflare/
│   │   ├── r2-bootstrap.sh
│   │   └── pages-notes.md
│   └── neon/
│       └── migrations.md
├── scripts/
│   ├── dev.sh
│   ├── test.sh
│   ├── smoke-test.sh
│   ├── check-free-tier.sh
│   └── backup-db.sh
├── docs/
│   ├── architecture.md
│   ├── deployment.md
│   ├── operations.md
│   ├── cost-guardrails.md
│   └── disaster-recovery.md
├── .env.example
├── .gitignore
├── docker-compose.yml
├── Makefile
├── README.md
└── plan.md
```

---

## 6. Environment contract

Create `.env.example` with names only, never real credentials.

```dotenv
APP_ENV=development
APP_ORIGIN=http://localhost:5173

DATABASE_URL=
DATABASE_URL_DIRECT=

R2_ENDPOINT_URL=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_BUCKET=
R2_PUBLIC_BASE_URL=

GCP_PROJECT_ID=
GCP_REGION=us-central1
CLOUD_RUN_SERVICE_NAME=zero-cloud-api
```

Production secrets must be stored in deployment-provider secret/environment configuration, not committed to Git.

---

# 7. Implementation sprints

## Sprint 0 — Establish the $0 contract

### Tasks

- [ ] Create a dedicated GitHub repository.
- [ ] Add this `plan.md` at repository root.
- [ ] Record the exact free-tier limits in `docs/cost-guardrails.md` with a `last_verified` date.
- [ ] Decide the primary GCP region. Default to `us-central1` unless latency/data-residency requirements dictate otherwise.
- [ ] Create a dedicated Google Cloud project for this stack so usage is easy to isolate.
- [ ] Create/enable a Cloudflare account.
- [ ] Create/enable a Neon account.
- [ ] Turn on MFA for GitHub, Cloudflare, Google Cloud, and Neon.
- [ ] Create a `.gitignore` that blocks `.env`, service-account material, local DB dumps, and secret files.
- [ ] Enable secret scanning / push protection on GitHub where available.

### Exit criteria

- Repo exists.
- No application services have been deployed yet.
- Cost envelope and providers are documented.
- Accounts are secured with MFA.

---

## Sprint 1 — Build a local vertical slice

Implement the smallest application proving all four service interfaces.

### API endpoints

```text
GET  /health
GET  /ready
GET  /api/items
POST /api/items
POST /api/files/presign-upload
GET  /api/files/{key}/presign-download
```

### Data model

Start with one tiny relational table:

```text
items
- id UUID primary key
- name text not null
- created_at timestamptz not null
```

### Tasks

- [ ] Bootstrap FastAPI app.
- [ ] Add Pydantic settings.
- [ ] Add SQLAlchemy session management.
- [ ] Add Alembic.
- [ ] Implement `/health` without external dependencies.
- [ ] Implement `/ready` that verifies DB connectivity.
- [ ] Implement CRUD for `items`.
- [ ] Implement R2 client abstraction using the S3 API.
- [ ] Implement presigned upload/download flows.
- [ ] Build a simple frontend displaying items and allowing a test file upload.
- [ ] Add unit tests.
- [ ] Add API integration tests.
- [ ] Add `docker-compose.yml` for local API + local Postgres.
- [ ] For object-storage integration tests, either mock S3 or run an S3-compatible local test service; do not make ordinary unit tests depend on production R2.

### Exit criteria

```bash
make test
make dev
```

must run locally with no cloud credentials required for the default test path.

---

## Sprint 2 — Provision Neon

### Tasks

- [ ] Create one Neon project for the application.
- [ ] Create production branch/database.
- [ ] Capture pooled `DATABASE_URL`.
- [ ] Capture direct connection URL if Alembic requires it.
- [ ] Require SSL.
- [ ] Run migrations against Neon.
- [ ] Execute create/read/update/delete smoke tests.
- [ ] Verify application connections close cleanly.
- [ ] Configure a conservative SQLAlchemy pool appropriate for serverless containers.

### Connection policy

Cloud Run may start multiple concurrent requests. Avoid opening a new PostgreSQL connection for every request.

Initial settings:

```text
Cloud Run max instances: 1
Cloud Run concurrency: 40-80
SQLAlchemy pool size: small
Neon pooled connection: yes
```

Tune only after measuring.

### Free-tier protection

- [ ] Check Neon usage after integration tests.
- [ ] Add a documented cleanup path for old test branches/data.
- [ ] Keep binary files and large JSON payloads out of Postgres.

### Exit criteria

- Database migrations can be applied repeatably.
- Cloud-style connection string works from local API.
- Schema is represented entirely by migration files.

---

## Sprint 3 — Provision R2

### Tasks

- [ ] Enable R2 subscription in Cloudflare.
- [ ] Create a private Standard-class bucket, e.g. `zero-cloud-prod`.
- [ ] Create scoped R2 API credentials.
- [ ] Permit only the minimum bucket access needed by the application.
- [ ] Configure API endpoint and bucket variables locally.
- [ ] Test PUT/GET/DELETE.
- [ ] Test presigned upload.
- [ ] Test presigned download.
- [ ] Set object key convention.

Recommended key layout:

```text
uploads/{user-or-tenant}/{yyyy}/{mm}/{uuid}-{safe_filename}
exports/{yyyy}/{mm}/{uuid}.json
backups/db/{yyyy}/{mm}/{dd}/...
```

### Application rules

- Never trust the filename supplied by a client as the full object key.
- Generate server-side unique object names.
- Record object metadata in Neon only when relational lookup is necessary.
- Apply file-size and content-type limits before issuing an upload URL.
- Keep bucket private by default.
- Prefer browser ↔ R2 data movement for large objects instead of browser → Cloud Run → R2.

### Exit criteria

A user can request a presigned upload, upload directly to R2, and retrieve the object without routing the object bytes through the Cloud Run container.

---

## Sprint 4 — Containerize the API

### Docker requirements

- non-root runtime user;
- deterministic dependency install;
- small runtime image;
- no secrets baked into image;
- listen on `$PORT`;
- health endpoint available;
- graceful SIGTERM handling.

### Tasks

- [ ] Build Docker image locally.
- [ ] Run it with environment variables only.
- [ ] Verify read-only/stateless assumptions.
- [ ] Verify restart does not destroy required data.
- [ ] Add `.dockerignore`.
- [ ] Add image vulnerability scanning in CI if available without charge.

### Exit criteria

```bash
docker build -t zero-cloud-api apps/api
docker run --rm -p 8080:8080 --env-file .env zero-cloud-api
```

passes the smoke-test suite.

---

## Sprint 5 — Deploy Cloud Run with cost-safe defaults

### Google Cloud bootstrap

- [ ] Create/select dedicated GCP project.
- [ ] Attach billing account; document that billing is required for Free Tier.
- [ ] Enable only APIs actually needed.
- [ ] Enable Cloud Run.
- [ ] Enable Artifact Registry only if required by the selected deploy workflow.
- [ ] Create least-privilege deployment identity for GitHub Actions.
- [ ] Prefer Workload Identity Federation over a long-lived service-account JSON key.

### Initial Cloud Run configuration

Use conservative defaults:

```text
billing model: request-based
min instances: 0
max instances: 1
CPU: 1 vCPU
memory: 512 MiB
concurrency: 80 (adjust based on tests)
timeout: 30 s
startup CPU boost: avoid unless required
session affinity: off
execution environment: current supported generation
```

The intent is:

```text
idle -> zero instances -> near-zero compute consumption
```

### Tasks

- [ ] Deploy API.
- [ ] Inject Neon/R2 credentials through Cloud Run runtime configuration.
- [ ] Do not place production secrets in Docker image or GitHub repository.
- [ ] Configure CORS only for the intended frontend origin(s).
- [ ] Verify `min-instances=0`.
- [ ] Verify `max-instances=1`.
- [ ] Run smoke tests against public deployment.
- [ ] Confirm a cold start after the service has scaled down.
- [ ] Inspect Cloud Run metrics after testing.

### Exit criteria

- API works remotely.
- Idle service scales to zero.
- No request requires local persistent disk.
- Maximum scale is bounded.

---

## Sprint 6 — Deploy frontend on Cloudflare Pages

### Tasks

- [ ] Create Pages project from GitHub repository.
- [ ] Configure `apps/web` as the build root.
- [ ] Configure production API base URL as a Pages environment variable.
- [ ] Deploy static site.
- [ ] Confirm client-side routes function on refresh.
- [ ] Enable standard cache behavior for fingerprinted static assets.
- [ ] Add custom domain only if one is already owned or domain cost is outside this $0 infrastructure constraint.

### Exit criteria

Browser workflow succeeds end-to-end:

```text
Pages -> Cloud Run -> Neon
Pages -> Cloud Run (presign) -> R2
Browser -> R2 direct object transfer
```

---

## Sprint 7 — Optional Cloudflare Worker gateway

Do not implement this sprint automatically. Add it only if it solves a concrete problem.

### Valid reasons

- map `/api/*` under a Cloudflare-controlled hostname;
- prevent ordinary users from needing the raw `run.app` URL;
- perform trivial edge authorization/header validation;
- implement lightweight cache/routing logic;
- mediate R2 access.

### Constraints

- Worker Free plan currently has a 100,000-request/day account limit.
- Pages Functions consume the same Workers request allowance.
- Free Worker CPU time per request is deliberately small.

### Tasks if selected

- [ ] Create minimal Worker.
- [ ] Use environment bindings/secrets.
- [ ] Forward only allowed methods/paths to Cloud Run.
- [ ] Strip untrusted forwarding headers.
- [ ] Add a trace/request ID.
- [ ] Avoid expensive JSON transformation at the edge.
- [ ] Add integration tests.

### Exit criteria

The Worker adds measurable security/routing value without duplicating application logic.

---

## Sprint 8 — Authentication and authorization

Choose the smallest solution appropriate to the project.

### For a public read-only portfolio app

Do not add authentication merely for architecture aesthetics.

### For user-specific/write functionality

- [ ] Select an auth provider or implement standards-based authentication.
- [ ] Validate authentication server-side in Cloud Run.
- [ ] Apply authorization per resource, not only per route.
- [ ] Never trust user IDs passed from the browser without validating identity.
- [ ] Protect write/presign endpoints.
- [ ] Rate-limit or otherwise constrain abuse-sensitive operations.

### R2 rule

Never expose R2 secret access keys to the browser. Browser uploads use short-lived presigned URLs or an appropriate Cloudflare binding/gateway.

---

## Sprint 9 — CI

Create `.github/workflows/ci.yml`.

### On every pull request

Backend:

- [ ] install locked dependencies;
- [ ] lint;
- [ ] type-check;
- [ ] unit tests;
- [ ] integration tests;
- [ ] migration sanity check;
- [ ] Docker build.

Frontend:

- [ ] install with lockfile;
- [ ] lint;
- [ ] type-check;
- [ ] tests;
- [ ] production build.

Security:

- [ ] dependency audit where useful;
- [ ] secret scan;
- [ ] ensure `.env` is not committed.

### Exit criteria

Broken tests, migrations, or builds block merge.

---

## Sprint 10 — CD without long-lived cloud keys

### Cloud Run

Use GitHub Actions + Google Workload Identity Federation.

Pipeline:

```text
merge to main
   ↓
CI passes
   ↓
authenticate via OIDC/WIF
   ↓
build container
   ↓
push image
   ↓
deploy Cloud Run revision
   ↓
smoke test
```

### Cloudflare Pages

Prefer Cloudflare's Git integration for frontend deploys unless there is a reason to centralize deployment in GitHub Actions.

### Database migrations

Do not blindly run migrations concurrently with application rollout.

Use:

```text
1. validate migration
2. apply backward-compatible migration
3. deploy API
4. run smoke tests
5. only later remove deprecated columns/code
```

### Exit criteria

A merge to `main` can deploy without storing a Google service-account private key in GitHub.

---

## Sprint 11 — $0 guardrails

This sprint is mandatory.

### Cloud Run guardrails

- [ ] `min-instances=0`.
- [ ] `max-instances=1` initially.
- [ ] 512 MiB memory initially.
- [ ] 1 vCPU initially.
- [ ] request timeout <= 30 seconds unless justified.
- [ ] prohibit unauthenticated expensive endpoints.
- [ ] use R2 direct transfer for large files.
- [ ] do not use Cloud Run as a file CDN.
- [ ] do not use always-on CPU allocation.
- [ ] avoid unnecessary cross-region calls.

### Google Cloud billing controls

- [ ] Create a very low monthly budget, e.g. `$1`.
- [ ] Configure notifications at multiple percentages/absolute thresholds.
- [ ] Document clearly: **Google budgets alert; they do not inherently hard-stop spend.**
- [ ] Evaluate an automated billing-disable emergency mechanism only if accepting that it can shut down project resources.
- [ ] Create a runbook for disabling the project manually.
- [ ] Review billing dashboard after every significant load test.

### Cloudflare guardrails

- [ ] Keep R2 objects below 10 GB-month total if strict $0 is required.
- [ ] Track R2 Class A/B operation counts.
- [ ] Use Standard storage for the free-tier assumption.
- [ ] Keep Workers/Pages Functions below the shared free request limit if Worker functions are used.
- [ ] Do not enable paid Workers features accidentally.

### Neon guardrails

- [ ] Track DB storage.
- [ ] Track CU-hour consumption.
- [ ] Delete unnecessary test data/branches.
- [ ] Keep object/blob data out of Postgres.
- [ ] Index deliberately; do not over-index tiny tables.

### Application-level guardrails

- [ ] maximum upload size;
- [ ] maximum page size / pagination;
- [ ] maximum query time where practical;
- [ ] maximum export size;
- [ ] no unbounded scraper endpoint;
- [ ] no endpoint that lets a client choose arbitrary CPU-intensive parameters;
- [ ] queue/reject expensive work rather than allowing unlimited concurrency;
- [ ] cache stable responses in browser/Cloudflare where appropriate.

### Exit criteria

A written `docs/cost-guardrails.md` explains exactly what can create a bill and how to stop it.

---

## Sprint 12 — Observability

The objective is useful debugging without buying an observability SaaS.

### Backend logs

Emit structured JSON logs:

```json
{
  "level": "info",
  "request_id": "...",
  "method": "GET",
  "path": "/api/items",
  "status": 200,
  "duration_ms": 18
}
```

Never log:

- database URLs;
- credentials;
- auth tokens;
- signed R2 URLs in full;
- sensitive request bodies.

### Metrics to inspect

Cloud Run:

- request count;
- latency;
- instance count;
- container CPU;
- container memory;
- response status;
- outbound transfer/billing.

Neon:

- storage;
- compute usage;
- connections;
- slow/expensive queries where available.

R2:

- stored bytes;
- Class A operations;
- Class B operations.

### Synthetic smoke test

`scripts/smoke-test.sh` should verify:

1. frontend responds;
2. API health responds;
3. database create/read round trip works;
4. presign works;
5. R2 small-object upload/download works;
6. cleanup succeeds.

---

## Sprint 13 — Backup and recovery

A free-tier architecture still needs recoverability.

### Database

- [ ] Keep Alembic migrations as schema source of truth.
- [ ] Create periodic logical exports only if project data warrants it.
- [ ] Store compressed dumps in R2 only while storage remains under the $0 envelope.
- [ ] Retention policy: keep few backups, not unlimited history.
- [ ] Test restoration into a disposable Neon branch/project periodically.

### R2

- [ ] Treat source files in Git/GitHub as separately recoverable.
- [ ] For important user uploads, decide whether the free-tier design provides sufficient durability/business continuity.
- [ ] Document what is and is not backed up.

### Exit criteria

`docs/disaster-recovery.md` contains a tested procedure for reconstructing the application from GitHub + database/object backups.

---

## Sprint 14 — Security hardening

- [ ] HTTPS only.
- [ ] Strict CORS allowlist.
- [ ] Secure headers on frontend/API.
- [ ] Validate all request bodies.
- [ ] Parameterized SQL through ORM/query layer.
- [ ] File upload size/type enforcement.
- [ ] Unique object keys.
- [ ] Private R2 bucket by default.
- [ ] Short presigned-URL expiration.
- [ ] Least-privilege R2 token.
- [ ] Least-privilege Google deploy/runtime identities.
- [ ] GitHub OIDC/WIF rather than static GCP key.
- [ ] Dependency updates automated where useful.
- [ ] Secrets rotated after accidental exposure; never merely delete them from latest Git commit.

---

## Sprint 15 — Performance optimization for free-tier efficiency

Optimize **cost per useful request**, not benchmark vanity metrics.

### API

- [ ] enable response compression only where it makes sense;
- [ ] paginate list endpoints;
- [ ] select only required DB columns;
- [ ] index frequently filtered fields;
- [ ] remove N+1 queries;
- [ ] batch DB operations;
- [ ] cache stable public data in the browser/edge;
- [ ] avoid CPU-heavy serialization loops.

### File flow

Preferred:

```text
Browser -> Cloud Run: request permission/presign
Browser -> R2: upload/download object directly
```

Avoid:

```text
Browser -> Cloud Run -> R2 -> Cloud Run -> Browser
```

for large files because it consumes Cloud Run CPU/runtime and Google network transfer unnecessarily.

### Exit criteria

Load test demonstrates the expected personal-project traffic while remaining far below all free-tier quotas.

---

# 8. Cost-control acceptance test

Before declaring the platform complete, test the following.

## Idle test

1. Send one request.
2. Wait for Cloud Run to become idle.
3. Confirm active instance count returns to zero.
4. Confirm no minimum instance is configured.

## File transfer test

1. Request upload permission from API.
2. Upload 10-100 MB test file directly to R2.
3. Verify Cloud Run does not carry the file body.
4. Delete test object.

## Abuse test

1. Attempt an oversized upload.
2. Attempt a huge pagination limit.
3. Attempt repeated expensive request parameters.
4. Confirm application rejects/bounds them.

## Failure test

1. Remove DB connectivity temporarily.
2. `/health` should still describe process health.
3. `/ready` should fail.
4. API should return controlled errors rather than leaking connection strings.

## Cost review

After load testing:

- inspect GCP Billing;
- inspect Cloud Run request/CPU/memory/network usage;
- inspect Neon compute/storage;
- inspect R2 storage/operations;
- record actual consumption in `docs/cost-guardrails.md`.

---

# 9. Definition of Done

The `$0 Cloud Stack` is complete when all of the following are true:

- [ ] Frontend is live on Cloudflare Pages.
- [ ] API is live on Cloud Run.
- [ ] Cloud Run scales to zero.
- [ ] Cloud Run maximum instances are explicitly bounded.
- [ ] Neon PostgreSQL stores relational data.
- [ ] Alembic manages schema migrations.
- [ ] R2 stores object data.
- [ ] Large uploads/downloads bypass Cloud Run.
- [ ] R2 bucket is private unless public access is deliberately required.
- [ ] GitHub CI passes.
- [ ] Production deployment is automated.
- [ ] No long-lived Google service-account key is stored in GitHub.
- [ ] No production secret is committed to the repository.
- [ ] Health/readiness endpoints exist.
- [ ] Structured logs exist.
- [ ] Smoke tests pass against production.
- [ ] Cost/usage dashboards have been reviewed.
- [ ] A low GCP budget alert is configured.
- [ ] Free-tier limits and failure modes are documented.
- [ ] Backup/recovery procedure is documented and tested.
- [ ] Current monthly infrastructure bill under normal target usage is $0.

---

# 10. Execution order for an autonomous coding agent

An implementation agent should execute the project in this order and should not skip ahead when an earlier gate fails.

```text
0. Read plan.md completely
1. Scaffold monorepo
2. Implement local API + frontend vertical slice
3. Add tests and CI
4. Integrate Neon
5. Integrate R2
6. Containerize API
7. Deploy Cloud Run with min=0/max=1
8. Deploy Cloudflare Pages
9. Run production smoke tests
10. Add GitHub OIDC/WIF deployment
11. Implement cost guardrails
12. Implement observability
13. Implement backup/recovery
14. Perform security review
15. Run bounded load test
16. Inspect provider usage dashboards
17. Update docs with measured usage
18. Declare done only if Definition of Done is satisfied
```

### Agent rules

The implementation agent must:

- never commit secrets;
- never enable a paid service merely to simplify implementation without documenting and obtaining approval;
- never increase Cloud Run `max-instances` above 1 during initial deployment;
- never set Cloud Run `min-instances` above 0;
- never store persistent application data on Cloud Run local filesystem;
- never place large blobs in Neon when they belong in R2;
- never proxy large object transfers through Cloud Run unless there is a concrete security requirement;
- never assume a provider's free-tier limits are unchanged—verify them before deployment;
- stop and surface a blocker if a required configuration would create unavoidable recurring cost;
- prefer reversible infrastructure changes;
- maintain `docs/deployment.md` as actual commands/configuration become known;
- update `docs/cost-guardrails.md` with measured post-deployment usage.

---

# 11. Phase-two capabilities after the base stack works

These are intentionally outside the initial build.

Possible additions that can still fit a near-$0 architecture:

- Cloudflare Worker gateway;
- Cloudflare Queues for small asynchronous workloads where free limits fit;
- scheduled Cloud Run Jobs for bounded batch tasks;
- GitHub Actions scheduled workflows for low-frequency jobs;
- client-side analytics that does not create an always-on backend;
- presigned multipart R2 uploads;
- temporary Neon branches for preview environments;
- separate dev/prod R2 prefixes or buckets;
- preview deployments from pull requests.

Do not add these until the simple architecture is operational and measured.

---

# 12. Non-goals

The initial $0 stack is **not** intended for:

- guaranteed high availability/SLA;
- unlimited public traffic;
- multi-terabyte storage;
- heavy streaming workloads;
- persistent GPU workloads;
- long CPU-intensive synchronous requests;
- high-volume video delivery from Cloud Run;
- enterprise secrets/compliance requirements;
- workloads where unexpected service shutdown is unacceptable.

If the project grows beyond these constraints, the correct outcome is to intentionally graduate to a paid architecture rather than contorting the system to remain at $0.

---

# 13. Final target state

```text
                         USER
                          │
                          ▼
                Cloudflare Pages
                static SPA / site
                          │
                          │ small JSON API requests
                          ▼
                  Google Cloud Run
                  FastAPI container
                  min=0 / max=1
                    │          │
              SQL   │          │ permissions/
                    │          │ presigning
                    ▼          ▼
              Neon Postgres   Cloudflare R2
              relational      files / datasets
                    ▲              ▲
                    │              │
                    └──── metadata┘

Large-object path:
USER ─────────────── direct signed transfer ──────────────► R2

Deployment:
GitHub ─► CI ─► Cloud Run
GitHub ─► Cloudflare Pages

Expected idle compute cost: $0
Target monthly infrastructure bill at personal-project scale: $0
```
