# Operations

This is a low-traffic, cost-bounded service, not a high-availability platform.
The most important operational signals are correctness, unexpected public
writes, provider usage, and any configuration drift outside the fixed envelope.

## Daily/weekly checks while active

- Confirm Pages and API health from a location outside the developer machine.
- Review Cloud Run error count, p95 latency, instance count, CPU, memory,
  billable instance time, outbound transfer, and log ingestion.
- Review Neon CU-hours, storage, connections, and slow/expensive queries.
- Review account-wide R2 stored bytes and Class A/B operations. The check prints
  per-bucket details but compares the sum to the account allowance. Unknown
  GraphQL action names require manual classification against current pricing.
- Review Google Billing actual and forecast cost. Never infer cost from a green
  health check or from an alerts-only budget remaining silent.
- Confirm production writes are still disabled unless an approved feature and
  real user authorization are active.

```bash
scripts/check-free-tier.sh --all
scripts/smoke-test.sh --api-url "$API_URL" --web-url "$WEB_URL"
```

## Health semantics

| Probe | Dependency | Expected | Meaning |
|---|---|---|---|
| `GET /health` | None | `200 {"status":"ok"}` | Process/event loop can respond |
| `GET /ready` | PostgreSQL | `200 {"status":"ready"}` | API can reach the database |
| `GET /api/items?limit=1&offset=0` | PostgreSQL | Bounded list response | Read path and schema work |

If `/health` fails, inspect the Cloud Run revision/container. If health passes
but readiness fails, treat it as a database/secret/network incident; do not
restart repeatedly because each cold start and secret/database access consumes
usage. R2 is deliberately absent from readiness so an object outage does not
remove the relational read service.

## Logs

The API emits one-line structured JSON request logs with request ID, method,
path, status, and duration. It must never log authorization headers, database
URLs, credentials, request bodies, or full presigned URLs. Query recent errors:

```bash
gcloud run services logs read "$CLOUD_RUN_SERVICE_NAME" \
  --project "$GCP_PROJECT_ID" --region "$GCP_REGION" \
  --limit 100 --log-filter 'severity>=ERROR'
```

Before increasing log retention/export, check pricing. Sample or suppress noisy
success logs before a traffic test rather than buying an observability service.

## Release and rollback

CI tags each image with the tested commit SHA. CD first deploys a unique tagged
revision at zero traffic, smoke tests that exact URL, and promotes the exact
revision only after success. A smoke failure leaves existing production traffic
unchanged and removes the public/tagged route on a best-effort basis; the
revision and its logs remain for diagnosis.

Candidate deployment never changes the service-wide unauthenticated invoker
binding. The candidate is IAM-smoked under either the current public or private
mode. After promotion, CD adds or removes only the `allUsers` `roles/run.invoker`
binding to reach the requested mode, verifies IAM, and smoke tests the stable
URL. If this post-promotion transition fails, inspect IAM immediately; do not
rerun blindly or assume the requested exposure mode was reached.

The protected `PRODUCTION_MIGRATION_REVISION` marker must equal the repository's
single Alembic head. An authorized operator updates it only after applying and
verifying that revision in Neon. CD then reads its one pinned direct-URL secret
and queries `alembic_version` before pushing an image. It never applies schema
changes; failure to verify blocks the release.

To inspect revisions:

```bash
gcloud run revisions list --service "$CLOUD_RUN_SERVICE_NAME" \
  --project "$GCP_PROJECT_ID" --region "$GCP_REGION"
```

Rollback traffic only to a revision compatible with the current database
schema and active Secret Manager versions. Never roll application code back
through a destructive schema migration. Prefer a forward fix; for a safe prior
revision, use the Cloud Run console or `gcloud run services update-traffic` and
then rerun the read-only smoke test and guardrail check.

Artifact cleanup retains three recent package versions and deletes versions
older than 14 days. A rollback older than that must be rebuilt from Git, so tag
important releases in Git and keep migrations backward compatible.

## Database operations

- Migrations are operator-serialized; Cloud Run startup never runs Alembic.
- Use the direct Neon URL only for migration/backup. Runtime uses pooled URL.
- Before a migration, create and verify a logical dump when the data warrants
  it, inspect generated SQL, and confirm the rollback/forward-fix strategy.
- Use `SELECT pg_database_size(current_database())` (the live check does this)
  and keep large JSON/binary data out of PostgreSQL.
- Remove test rows/branches deliberately after validation.

## R2 operations

- Keep the bucket private and Standard-class.
- Browser transfer requires exact-origin CORS. CORS is not authorization; the
  presigned operation/key/expiry supplies temporary authority.
- If a full smoke test fails after upload, the script uses scoped S3 credentials
  to delete the exact generated object and reports cleanup failure loudly.
- `--r2` transfers 10 MiB by default to satisfy the acceptance test. A custom
  `--r2-size-bytes` must remain between 10 and 100 MiB and cannot exceed the
  deployed API's `MAX_UPLOAD_BYTES` value exported to the operator shell.
- Do not bulk-delete during an incident. Capture the exact bucket/key/prefix and
  verify backups/ownership first.

## Incident runbooks

### Cost/traffic spike

1. Disable application writes; revoke the R2 token if presign abuse is involved.
2. Remove public Cloud Run invoker access if reads are also abusive.
3. Inspect the billed meter before changing quotas or architecture.
4. Keep minimum zero/maximum one. Do not solve latency by raising scale.
5. Follow the stop procedure in `cost-guardrails.md` and record actual usage.

### Database unavailable

1. Confirm `/health` remains 200 and `/ready` is a controlled 503.
2. Inspect Neon project status, CU allowance, storage, role, TLS URL, and pooled
   endpoint. Do not paste the URL into tickets/logs.
3. Validate the pinned Secret Manager version and runtime secret accessor IAM.
4. Restore into a disposable target only if corruption/data loss is confirmed.

### R2 transfer unavailable

1. Confirm relational reads remain healthy.
2. Check R2 status, token scope, bucket name, endpoint, CORS exact origin, URL
   expiry, signed content type, and account subscription state.
3. Rotate credentials if exposure is possible; update the pinned secret version
   and redeploy. Destroy the old version/token after validation.

### Suspected credential disclosure

Rotate/revoke at the provider first. Removing a value from the latest Git commit
does not revoke it or erase history. Search logs/artifacts, invalidate URLs/tokens,
rewrite Git history only with coordinated incident handling, and document scope.

## Maintenance record

After deployments, load tests, rotations, backups, and recovery drills, record
the date, tested SHA, operator, results, provider usage, and cleanup confirmation.
No live usage or recovery drill has been performed by this repository scaffold.
