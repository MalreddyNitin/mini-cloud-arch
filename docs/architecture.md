# Architecture

## System context

```text
                         GitHub
                    source + CI checks
                     |              |
           Pages Git integration    | GitHub OIDC -> Google WIF
                     v              v
Browser --------> Cloudflare      Artifact Registry -> Cloud Run
  |                 Pages                              FastAPI
  |                   |                                  |  |
  |                   +------ small JSON requests -------+  |
  |                                                      |  |
  +--------- short-lived signed PUT/GET ---------------->R2 |
                                                         Neon
```

The frontend is a static Vite application on Cloudflare Pages. The API is a
stateless FastAPI container on request-billed Cloud Run. Neon stores relational
records; a private R2 Standard bucket stores object bytes. Cloud Run only grants
short-lived, object-specific R2 URLs. It does not proxy the object body.

No remote component shown above has been provisioned by the repository. The
code, workflows, dry-run automation, and operator runbooks are implementation
artifacts; provider state must be created and independently verified.

## Runtime boundaries

| Boundary | Accepted traffic | Persistent state | Authentication baseline |
|---|---|---|---|
| Pages | Public HTTPS static assets | Built assets only | Public read |
| Cloud Run | HTTPS JSON API | None; local filesystem is disposable | Private by default; public read-only is an explicit deploy setting |
| Neon | PostgreSQL/TLS from API/operator | `items` and future relational metadata | Database role in Secret Manager |
| R2 | S3 API from API; signed direct browser transfer | Files/exports/backups | Private bucket, scoped token, short presigned URL |
| GitHub to GCP | Deploy only | Container artifact/revision | OIDC -> WIF -> deploy service account; no private key |

The production security decision for the initial app is public **read-only**.
`ENABLE_WRITES=false` is the application default. Item writes and both presign
operations return a controlled denial. Operators can enable them for a bounded
test using a server-side key, but a browser must never receive that shared key.
Before user-facing writes are launched, add standards-based identity and
resource-level authorization.

## Request and data flows

### Read path

1. Browser loads hashed static assets from Pages.
2. Browser calls a bounded `GET /api/items` request.
3. Cloud Run reuses a small pooled Neon connection and returns JSON.
4. Browser caching handles stable assets/data where appropriate.

### Object path when writes are authorized

1. Client sends filename metadata, content type, and size—not file bytes—to the
   protected presign endpoint.
2. API validates authorization, size, type, and creates a unique server-owned
   key such as `uploads/<tenant>/<yyyy>/<mm>/<uuid>-<safe-name>`.
3. API signs a five-minute R2 PUT URL.
4. Browser uploads directly to R2; R2 CORS admits only the exact Pages origin.
5. Download authorization produces a short GET URL, again without proxying data.

### Deployment path

CI independently gates backend tests/types/migrations, frontend tests/build,
shell/Compose policy, container runtime behavior, and a vulnerability scan.
After successful CI on `main`, `deploy-api.yml` obtains a short GitHub OIDC
token. Google's WIF provider admits only the exact repository and `main` ref,
then permits impersonation of the deploy service account. A protected migration
revision marker must match the repository's single Alembic head. The workflow
builds and pushes a commit-SHA image, deploys a tagged candidate with fixed
scaling limits and zero traffic, and runs read-only smoke tests against its tag
URL using Cloud Run IAM. Candidate creation preserves the current service IAM;
only after that tested revision is promoted does CD reconcile and verify the
requested public/private invoker mode. The workflow reads
one pinned direct Neon URL transiently to compare the actual `alembic_version`;
it cannot run migrations. Other application values are bound directly to Cloud
Run from pinned Secret Manager versions.

Pages uses Cloudflare's GitHub App instead of a Cloudflare API token stored in
GitHub. Production database migrations are a separate, serialized operator step
using expand/migrate/contract, not an automatic container startup side effect.
The migration marker is an operator attestation, not a replacement for checking
the production database after applying a migration.

## Failure behavior

- `/health` reports process health without dependencies. `/ready` returns 503
  when PostgreSQL is unavailable, keeping secret details out of the response.
- R2 failure affects presign/object workflows, not process health or item reads.
- Cloud Run instances can disappear at any time; all durable state is external.
- With `min-instances=0`, the first request after idle can experience a cold
  start. This is accepted in exchange for zero idle compute allocation.
- `max-instances=1` protects cost but limits availability/throughput. Overload
  should queue briefly at the platform or fail, never silently scale into cost.

The optional Worker gateway is intentionally absent. Add it only for a measured
routing/security need and re-review the shared Workers/Pages Functions quota.
