# Zero Cloud Stack

A production-shaped, cost-bounded application template using a static React
frontend, FastAPI, PostgreSQL, and S3-compatible object storage. The intended
hosted architecture is Cloudflare Pages + private Cloudflare R2 + Google Cloud
Run + Neon Postgres, with GitHub Actions deploying through Google Workload
Identity Federation.

The repository implements the application, tests, local stack, CI/CD,
dry-run-safe bootstrap/deploy tooling, smoke/load/backup utilities, and
runbooks. **It does not claim that any cloud account, billing link, MFA setting,
budget, database, bucket, Pages project, or Cloud Run service has been created.**

## Current safety contract

- Cloud Run configuration is fixed at request-based CPU, minimum 0, maximum 1,
  1 vCPU, 512 MiB, concurrency 80, and a 30-second timeout.
- Production writes and R2 presign endpoints are disabled by default. The base
  public product is read-only. User-facing writes require real authentication
  and resource authorization; a shared operator key must never enter the web
  bundle.
- R2 remains private and Standard-class. Large object bytes move directly
  between browser and R2 through short-lived signed URLs.
- Google deployment uses GitHub OIDC/WIF and pinned Secret Manager references;
  no long-lived service-account JSON key is accepted.
- Production CD requires both an operator marker and a read-only check of the
  actual Neon migration head, scans/deploys an immutable image digest, stages a
  tagged revision at zero traffic, and only promotes it after smoke tests.
- Provider Free Tier is an allowance, not a guarantee. Limits and official
  source links were last verified on 2026-08-15 in
  [`docs/cost-guardrails.md`](docs/cost-guardrails.md).

## Repository map

```text
apps/api/                 FastAPI, SQLAlchemy, Alembic, R2 client, tests
apps/web/                 React/Vite static frontend and tests
.github/workflows/        CI and WIF-based Cloud Run deployment
infra/gcp/                dry-run GCP/WIF/bootstrap and fixed Cloud Run deploy
infra/cloudflare/         private R2 bootstrap and Pages settings
infra/neon/               migration/provisioning runbook
scripts/                  dev, test, smoke, load, guardrail, and backup tools
docs/                     architecture and operator runbooks
docker-compose.yml        loopback-only local PostgreSQL + API
```

## Local quick start

Prerequisites: Python 3.12+, Node 20+, npm, Docker with Compose v2, Bash, and
GNU Make (optional). Git Bash or WSL provides the intended shell on Windows.

```bash
cp .env.example .env
make test
make dev-detached
scripts/smoke-test.sh --api-url http://localhost:8080
```

The local API and PostgreSQL bind only to loopback. Compose applies Alembic
migrations before starting the API and enables local writes without a key. No
cloud credentials are required unless you deliberately configure R2.

Run the frontend in another shell:

```bash
cd apps/web
npm ci
npm run dev
```

Open `http://localhost:5173`. Stop the containers without deleting the local
database volume:

```bash
docker compose down
```

To delete the development volume, use an explicit operator command only after
confirming no local data is needed; the project scripts never remove it.

## API surface

| Method/path | Purpose | Production default |
|---|---|---|
| `GET /health` | Process health, no dependencies | Public/readable |
| `GET /ready` | PostgreSQL readiness | Public/readable |
| `GET /api/items` | Bounded item list | Public/readable |
| `POST /api/items` | Create item | Disabled |
| `PATCH /api/items/{id}` | Update item | Disabled |
| `DELETE /api/items/{id}` | Delete item | Disabled |
| `POST /api/files/presign-upload` | Short direct R2 PUT permission | Disabled |
| `GET /api/files/{key}/presign-download` | Short direct R2 GET permission | Disabled |

Set `ENABLE_WRITES=true` only in a protected environment. Production startup
then requires `WRITE_API_KEY` with at least 32 characters, supplied as a
server-side bearer token. This operator mechanism is not browser authentication.

## Useful commands

```bash
make help                 # discover targets
make test                 # backend/frontend/static checks, no cloud needed
make dev                  # foreground PostgreSQL + API
make smoke                # health/readiness/read check
make smoke-full           # protected DB + 10 MiB direct R2 round trip and cleanup
make load-test            # bounded loopback read probe
make check-free-tier      # repository guardrail policy
make backup-db            # verified custom-format pg_dump
```

All mutating infrastructure scripts print a dry run unless `--apply` is
explicitly supplied. See `--help` on every script before using provider access.

## Deploy

Deployment is an operator-controlled sequence, not a one-click claim:

1. Secure accounts and re-check the current cost contract.
2. Provision Neon, review/apply migrations once, and record the verified head in
   the protected production migration marker.
3. Create the private Standard R2 bucket and scoped credentials.
4. Review/apply GCP project, registry cleanup, WIF/IAM, and alerts-only budget.
5. Put runtime values in pinned Secret Manager versions and configure non-secret
   GitHub variables.
6. Protect the GitHub `production` environment and keep
   `ENABLE_PRODUCTION_DEPLOY` unset until every provider variable, pinned secret,
   and migration gate is ready.
7. Set `ENABLE_PRODUCTION_DEPLOY=true`, deploy the API, verify scale-to-zero and
   usage, then connect Pages via its
   native Git integration.

Exact commands, roles, variables, and verification gates are in
[`docs/deployment.md`](docs/deployment.md). Cloudflare Pages settings are in
[`infra/cloudflare/pages-notes.md`](infra/cloudflare/pages-notes.md).

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — boundaries and data flows
- [`docs/cost-guardrails.md`](docs/cost-guardrails.md) — verified limits,
  bill triggers, live checks, and stop procedure
- [`docs/deployment.md`](docs/deployment.md) — provider setup and WIF release
- [`docs/operations.md`](docs/operations.md) — monitoring and incident runbooks
- [`docs/disaster-recovery.md`](docs/disaster-recovery.md) — backup, restore,
  reconstruction, and untested assumptions
- [`docs/security.md`](docs/security.md) — threat model and acceptance checks
- [`docs/performance.md`](docs/performance.md) — bounded measurement/tuning
- [`docs/execution-status.md`](docs/execution-status.md) — Sprint 0–15 and
  Definition-of-Done evidence

The platform is ready for local verification and authorized provisioning. It is
not “done” in the hosted sense until the production smoke, scale-to-zero, usage,
billing, backup-restore, and security acceptance evidence is recorded.
