# Execution status

```yaml
as_of: 2026-08-15
source_plan: plan.md
hosted_state: GitHub repository and CI active; application providers not provisioned
production_usage: not measured
repository_publication: main published at 65396aace1156113d476c8738554314119ed6b7e
```

This record distinguishes repository implementation from provider-side proof.
The local application, automation, and runbooks are substantially complete, but
the stack is not production-complete and the Definition of Done is not met.

## Status meanings

- **Proven locally**: exercised in this checkout with local tests, containers, or
  static policy checks.
- **Implemented, not live-verified**: code/runbooks exist, but the required
  provider resource or hosted behavior has not been exercised.
- **Blocked externally**: completion requires authenticated account access,
  provider state, or an operator-controlled setting that is unavailable here.
- **Not selected**: an explicitly optional scope was deliberately omitted.

## Sprint evidence

| Sprint | Status | Evidence and remaining gate |
|---|---|---|
| 0 — $0 contract | **Partly proven; blocked externally** | The public GitHub repository exists, `plan.md` and dated free-tier limits are published, `us-central1` is selected, and secret scanning/push protection are enabled. `main` requires pull requests and the four CI checks; force-push and deletion are disabled. GitHub MFA could not be read with the available token, and Cloudflare/Google/Neon accounts, projects, billing, MFA, and the $1 budget remain unverified. |
| 1 — Local vertical slice | **Proven locally** | FastAPI, React, PostgreSQL, Alembic, mocked S3/R2, CRUD, direct-upload UI, Compose, unit/integration tests, and no-cloud local paths were exercised. |
| 2 — Neon | **Implemented, not live-verified** | Pooled/direct URL separation, required production TLS, bounded pool/connect/query timeouts, migrations, cleanup, and usage instructions exist. No Neon project, migration run, CRUD smoke, connection observation, or usage review has been performed. |
| 3 — R2 | **Implemented, not live-verified** | Private Standard-bucket bootstrap, exact-origin CORS, scoped-key instructions, generated keys, signed exact upload length, type/size bounds, short PUT/GET URLs, direct-transfer smoke, and cleanup exist. No subscription, bucket, token, object transfer, privacy check, or usage review has been performed. |
| 4 — API container | **Proven locally and in hosted CI** | The runtime uses immutable `python:3.12.13-slim-bookworm` content, deterministic dependency pins, non-root UID 10001, `$PORT`, health check, graceful stop, and external state. Local and hosted builds/smoke passed; Trivy 0.70.0 reported zero fixed HIGH/CRITICAL findings after the FastAPI 0.141.1 / Starlette 1.3.1 remediation. |
| 5 — Cloud Run | **Implemented, not live-verified** | Dry-run bootstrap and deployment fix min 0/max 1, 1 CPU, 512 MiB, concurrency 80, 30-second timeout, request CPU, no boost/affinity, zero-traffic candidate smoke, digest promotion, and deferred IAM reconciliation. No GCP resource exists and scale-to-zero, cold start, metrics, CORS, and remote smoke remain blocked. |
| 6 — Pages | **Implemented, not live-verified** | The static build, mandatory HTTPS API origin, refresh fallback, immutable asset cache policy, and exact Pages settings exist. No Pages project/deploy or hosted browser workflow has been exercised. The chosen public read-only production posture intentionally cannot authorize browser uploads; user-facing uploads require real identity/resource authorization before this exit can pass. |
| 7 — Optional Worker | **Not selected** | No measured routing or security need justified consuming the shared Workers/Pages Functions allowance. The decision is recorded in `docs/architecture.md`. |
| 8 — Authentication | **Public read-only decision proven locally** | Production mutations and presigning default to disabled. Enabling them requires a strong server-side operator bearer that is never placed in the web bundle. This is appropriate for the selected public read-only base; standards-based auth, per-resource authorization, and abuse controls are still required if user-facing writes/uploads enter scope. |
| 9 — CI | **Proven in hosted GitHub Actions** | Run [31924021290](https://github.com/MalreddyNitin/mini-cloud-arch/actions/runs/31924021290) passed Backend, Frontend, Repository policy, and Container jobs, including PostgreSQL migrations, tests/builds, non-root health smoke, and the exact-image Trivy gate. Those four checks are required on protected `main`. |
| 10 — Keyless CD | **Implemented, not live-verified** | Only a successful trusted-repository `push` CI run can deploy. WIF is repository/branch restricted; production migration state is queried; the exact scanned digest is deployed through candidate smoke and promotion. WIF, environments, secrets, registry, service, and Pages Git integration do not exist yet. |
| 11 — $0 guardrails | **Proven locally; live controls blocked** | Static/live checks cover Cloud Run drift, account-wide R2 usage, Neon usage, bounded inputs, budgets, and stop procedures. The budget and provider dashboards have not been created or inspected. |
| 12 — Observability | **Proven locally; hosted metrics blocked** | Structured JSON request logs use route templates and omit dynamic object keys; raw Uvicorn access logs are disabled. Smoke tooling covers web, process, DB, direct R2 transfer, and cleanup. Cloud Run/Neon/R2 metrics and production logs remain uninspected. |
| 13 — Recovery | **Implemented; exit not met** | Alembic, validated logical dump tooling, bounded retention, reconstruction, and data-loss limitations are documented. No restore into a disposable Neon target and no live R2 backup verification have been recorded. |
| 14 — Security | **Repository/application controls proven; provider controls blocked** | Read-only defaults, write protection, CORS, headers, validation, ORM queries, upload/key bounds, short URLs, private-bucket automation, least-privilege/WIF design, Dependabot, and scanning exist. GitHub secret scanning, push protection, Dependabot security updates, and protected `main` are live. Provider MFA, real R2 token scope/privacy, and Google IAM still require operator verification. |
| 15 — Performance | **Local baseline proven; live acceptance blocked** | Pagination, compact queries, small DB pool, timeouts, direct object flow, response compression, and a bounded load tool exist. The recorded loopback baseline is 50 requests at concurrency 2, 0 errors, and p95 24.6 ms. Production quota headroom and usage remain unmeasured. |

## Local verification record

The following results were observed on 2026-08-15:

| Gate | Result |
|---|---|
| Backend | Ruff and format checks passed; strict mypy passed for 19 source files; 36 tests passed with 90.92% coverage; Alembic migration/drift checks passed. |
| Frontend | ESLint and strict type-check passed; 16 Vitest tests passed; production build passed; a production build without a valid HTTPS API origin failed as intended; production dependency audit reported zero vulnerabilities. |
| Container/local integration | Image built; UID 10001 and alternate `$PORT` were verified; health and graceful stop passed. Compose PostgreSQL/API migrations, health/readiness, CRUD round trip, cleanup, and repository smoke passed. |
| Platform policy | Shell/static policy suite passed with zero failures/warnings; 15 helper/contract tests passed; Compose and workflow syntax parsed. Public and private deployment dry runs kept candidate deployment IAM-neutral and deferred service IAM reconciliation until after promotion. |
| Bounded load | 50 read requests, concurrency 2, zero errors; mean 15.9 ms, p50 13.6 ms, p95 24.6 ms, p99/max 56.5 ms. This is loopback evidence, not Cloud Run evidence. |

These point-in-time local results are complemented by the successful hosted CI
run linked above. They are reproducible through `make test`,
`scripts/smoke-test.sh`, and the commands in `docs/performance.md`.

## Cost-control acceptance

| Acceptance test | Status |
|---|---|
| Idle / scale to zero | **Blocked externally** — configuration is fixed at min 0, but instance-count evidence requires a deployed Cloud Run service and an idle observation window. |
| Direct file transfer | **Implemented, not live-verified** — the explicit R2 smoke defaults to the plan's 10 MiB minimum and exercises presign, direct PUT/GET, comparison, and cleanup without proxying bytes; real R2 credentials/resources are absent. |
| Abuse bounds | **Proven locally** — oversized/type-disallowed uploads, excessive pagination, unsafe keys, disabled writes, and bounded load parameters are rejected or capped. |
| Dependency failure | **Proven locally** — `/health` remains process-only while `/ready` returns a controlled 503 for database failure without exposing a connection string. A hosted failure drill is still pending. |
| Provider cost review | **Blocked externally** — GCP billing, Cloud Run, Neon, and R2 dashboards contain no deployment measurements to record. |

## Definition of Done

| Requirement | Status |
|---|---|
| Frontend live on Pages; API live on Cloud Run | **Blocked externally** |
| Cloud Run scales to zero | **Blocked externally**; safe configuration exists |
| Cloud Run maximum instances explicitly bounded | **Implemented, not live-verified** |
| Neon stores relational data | **Blocked externally** |
| Alembic manages schema | **Proven locally** |
| R2 stores objects and remains private | **Blocked externally**; bootstrap and checks exist |
| Large object bytes bypass Cloud Run | **Implemented, not live-verified** |
| GitHub CI passes and production deployment is automated | **CI proven hosted**; keyless deployment workflow is implemented but intentionally opt-in and not live-verified |
| No long-lived Google key or committed production secret | **Proven for the tree and GitHub controls**; live Google WIF remains unconfigured |
| Health/readiness and structured logs exist | **Proven locally** |
| Production smoke passes | **Blocked externally** |
| Cost/usage dashboards reviewed and low budget configured | **Blocked externally** |
| Free-tier limits/failure modes documented | **Proven locally** |
| Recovery documented and restore tested | **Documented; live restore test blocked** |
| Normal monthly infrastructure bill is $0 | **Blocked externally and unmeasured** |

## Required continuation order

Repository publication, hosted CI, and the available GitHub repository controls
are complete. Continue in this order without declaring production completion
early:

1. Verify MFA across GitHub, Cloudflare, Google Cloud, and Neon; obtain
   authenticated provider access. GitHub environment protection remains tied to
   the future production deployment setup.
2. Provision Neon and R2, apply the migration, run CRUD/direct-object smoke, and
   inspect initial usage.
3. Bootstrap GCP/WIF/budget/secrets, deploy Cloud Run, prove cold start and
   scale-to-zero, and inspect metrics/billing.
4. Connect Pages, configure the production API origin, and verify route refresh
   and browser reads. Decide and implement real authentication before claiming
   user-facing uploads.
5. Run the production acceptance suite, a disposable restore drill, bounded
   load, dashboard review, and record actual consumption and bill evidence.
