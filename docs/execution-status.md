# Execution status

```yaml
as_of: 2026-08-15
source_plan: plan.md
hosted_state: not provisioned
production_usage: not measured
repository_publication: initial main publication pending
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
| 0 — $0 contract | **Partly proven; blocked externally** | `plan.md`, dated free-tier limits, `us-central1`, secret hygiene, and provider/cost runbooks exist. Initial publication is pending. Provider accounts/projects, billing, MFA, GitHub push protection/secret scanning, and the $1 budget are not verified. |
| 1 — Local vertical slice | **Proven locally** | FastAPI, React, PostgreSQL, Alembic, mocked S3/R2, CRUD, direct-upload UI, Compose, unit/integration tests, and no-cloud local paths were exercised. |
| 2 — Neon | **Implemented, not live-verified** | Pooled/direct URL separation, required production TLS, bounded pool/connect/query timeouts, migrations, cleanup, and usage instructions exist. No Neon project, migration run, CRUD smoke, connection observation, or usage review has been performed. |
| 3 — R2 | **Implemented, not live-verified** | Private Standard-bucket bootstrap, exact-origin CORS, scoped-key instructions, generated keys, signed exact upload length, type/size bounds, short PUT/GET URLs, direct-transfer smoke, and cleanup exist. No subscription, bucket, token, object transfer, privacy check, or usage review has been performed. |
| 4 — API container | **Proven locally** | Deterministic image build, non-root UID 10001, `$PORT`, health check, graceful stop, external state, and container smoke passed locally. CI defines an exact-image Trivy scan. |
| 5 — Cloud Run | **Implemented, not live-verified** | Dry-run bootstrap and deployment fix min 0/max 1, 1 CPU, 512 MiB, concurrency 80, 30-second timeout, request CPU, no boost/affinity, zero-traffic candidate smoke, digest promotion, and deferred IAM reconciliation. No GCP resource exists and scale-to-zero, cold start, metrics, CORS, and remote smoke remain blocked. |
| 6 — Pages | **Implemented, not live-verified** | The static build, mandatory HTTPS API origin, refresh fallback, immutable asset cache policy, and exact Pages settings exist. No Pages project/deploy or hosted browser workflow has been exercised. The chosen public read-only production posture intentionally cannot authorize browser uploads; user-facing uploads require real identity/resource authorization before this exit can pass. |
| 7 — Optional Worker | **Not selected** | No measured routing or security need justified consuming the shared Workers/Pages Functions allowance. The decision is recorded in `docs/architecture.md`. |
| 8 — Authentication | **Public read-only decision proven locally** | Production mutations and presigning default to disabled. Enabling them requires a strong server-side operator bearer that is never placed in the web bundle. This is appropriate for the selected public read-only base; standards-based auth, per-resource authorization, and abuse controls are still required if user-facing writes/uploads enter scope. |
| 9 — CI | **Implemented and locally exercised; first hosted run pending** | Locked installs, lint, type checks, backend/PostgreSQL integration, migration checks, frontend tests/build, policy checks, container smoke, dependency audit, and Trivy are defined. Hosted evidence begins with the initial push. |
| 10 — Keyless CD | **Implemented, not live-verified** | Only a successful trusted-repository `push` CI run can deploy. WIF is repository/branch restricted; production migration state is queried; the exact scanned digest is deployed through candidate smoke and promotion. WIF, environments, secrets, registry, service, and Pages Git integration do not exist yet. |
| 11 — $0 guardrails | **Proven locally; live controls blocked** | Static/live checks cover Cloud Run drift, account-wide R2 usage, Neon usage, bounded inputs, budgets, and stop procedures. The budget and provider dashboards have not been created or inspected. |
| 12 — Observability | **Proven locally; hosted metrics blocked** | Structured JSON request logs use route templates and omit dynamic object keys; raw Uvicorn access logs are disabled. Smoke tooling covers web, process, DB, direct R2 transfer, and cleanup. Cloud Run/Neon/R2 metrics and production logs remain uninspected. |
| 13 — Recovery | **Implemented; exit not met** | Alembic, validated logical dump tooling, bounded retention, reconstruction, and data-loss limitations are documented. No restore into a disposable Neon target and no live R2 backup verification have been recorded. |
| 14 — Security | **Proven locally; provider controls blocked** | Read-only defaults, write protection, CORS, headers, validation, ORM queries, upload/key bounds, short URLs, private-bucket automation, least-privilege/WIF design, Dependabot, and scanning exist. MFA, real token scope, bucket privacy, IAM, branch protection, and hosted secret controls need operator verification. |
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

These are point-in-time results, not a substitute for the first hosted GitHub CI
run. They are reproducible through `make test`, `scripts/smoke-test.sh`, and the
commands in `docs/performance.md`.

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
| GitHub CI passes and production deployment is automated | **Pending hosted evidence**; workflows are ready for the initial push |
| No long-lived Google key or committed production secret | **Proven for the local tree**; hosted settings remain unverified |
| Health/readiness and structured logs exist | **Proven locally** |
| Production smoke passes | **Blocked externally** |
| Cost/usage dashboards reviewed and low budget configured | **Blocked externally** |
| Free-tier limits/failure modes documented | **Proven locally** |
| Recovery documented and restore tested | **Documented; live restore test blocked** |
| Normal monthly infrastructure bill is $0 | **Blocked externally and unmeasured** |

## Required continuation order

The earliest failing gate remains repository publication. Continue in this
order without declaring hosted completion early:

1. Review the complete initial tree, preserve Linux executable bits, commit,
   push, and observe the first CI run.
2. Enable MFA, branch/environment protections, secret scanning, and push
   protection; then record evidence.
3. Provision Neon and R2, apply the migration, run CRUD/direct-object smoke, and
   inspect initial usage.
4. Bootstrap GCP/WIF/budget/secrets, deploy Cloud Run, prove cold start and
   scale-to-zero, and inspect metrics/billing.
5. Connect Pages, configure the production API origin, and verify route refresh
   and browser reads. Decide and implement real authentication before claiming
   user-facing uploads.
6. Run the production acceptance suite, a disposable restore drill, bounded
   load, dashboard review, and record actual consumption and bill evidence.
