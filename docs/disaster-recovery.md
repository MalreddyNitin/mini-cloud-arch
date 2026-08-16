# Disaster recovery

The recovery objective is reconstruction of a small personal-project service,
not zero data loss or a formal SLA. Until a real restore drill records measured
times, RPO and RTO are **unknown**. Neon time-travel/retention on Free is limited
and provider-plan-dependent; a logical export is the portable recovery asset.

## Recoverability inventory

| Asset | Source of truth | Recovery method |
|---|---|---|
| Application and infrastructure code | GitHub + local clone | Checkout a reviewed tag/SHA |
| Database schema | Alembic migrations | `alembic upgrade head` |
| Relational data | Neon plus verified `pg_dump` | `pg_restore` into a clean target |
| R2 objects | Private R2 bucket | Provider durability; optional independent copy by data value |
| Runtime configuration | Runbooks + provider settings | Recreate; secret **values** remain in a secure password/recovery system |
| Container image | Artifact Registry (short retention) | Rebuild exact Git SHA |

Git is not a backup for Neon rows or user uploads. R2 database dumps share the
Cloudflare account/failure domain with object data, so they protect primarily
against database failure—not total Cloudflare account loss. Important user data
requires an independent backup target, which may be outside the $0 constraint.

## Create and verify a logical backup

```bash
export DATABASE_URL_DIRECT='<tls-direct-neon-url>'
scripts/backup-db.sh

# Optional R2 copy; verifies exact size and SHA-256 metadata before deletion.
scripts/backup-db.sh --upload-r2 --delete-local
```

The script produces PostgreSQL custom format with no ownership/ACL statements,
validates its table of contents with `pg_restore --list`, and prints the local
byte count and SHA-256 for the drill record. An R2 upload stores that SHA-256 as
object metadata, reads the object metadata back, and requires both the exact
remote byte count and checksum to match. Missing or mismatched evidence fails
closed and preserves the local dump. Local dumps live under ignored `backups/`.
The script never automatically prunes retention; keep only a small deliberate
set so R2 stays within its storage envelope.

Backups can contain sensitive/user data. Encrypt or choose an appropriate
independent destination if the data classification requires it. Do not attach
dumps to issues or CI artifacts.

## Restore drill (disposable target)

Never test restore over production. Create a disposable Neon project/branch or
local PostgreSQL database with sufficient space, then:

```bash
createdb zero_cloud_restore
pg_restore --exit-on-error --no-owner --no-acl \
  --dbname zero_cloud_restore backups/db/<verified-file>.dump

DATABASE_URL='postgresql+psycopg://localhost/zero_cloud_restore' \
DATABASE_URL_DIRECT='postgresql+psycopg://localhost/zero_cloud_restore' \
  bash -c 'cd apps/api && alembic current && alembic upgrade head'
```

Start the API against the restore target, run `/ready`, verify representative
row counts/content, create/read/delete a test item with writes explicitly
enabled, and record results. Destroy the disposable target only after the drill
record and any needed evidence are retained. Deleting a Neon test branch/project
is an operator action; the repository does not automate it.

## Full reconstruction

1. Declare the incident, freeze writes, preserve logs, and identify the last
   trustworthy Git SHA, database dump, and object boundary.
2. Secure accounts and rotate compromised credentials before restoration.
3. Recreate a dedicated GCP project using the reviewed bootstrap dry run, then
   restore WIF/IAM/budget/registry. Do not reuse unknown compromised identities.
4. Recreate Neon, apply schema migrations, then restore relational data. Resolve
   schema/dump version deliberately; never force a destructive migration.
5. Recreate the private Standard R2 bucket/CORS and restore independently backed
   objects if R2 itself was lost. Database metadata must not claim objects exist
   until object verification succeeds.
6. Recreate pinned Secret Manager values/versions and grant only the runtime
   identity access. Build the exact reviewed image from Git.
7. Deploy privately with minimum zero/maximum one. Run authenticated read-only,
   database mutation, and direct R2 transfer/cleanup tests.
8. Reconnect Pages only after the restored API is correct; make the API public
   read-only if required and monitor cost/error metrics closely.
9. Document recovery time, data loss boundary, usage, and corrective actions.

## R2 object recovery policy

Source-controlled static assets can be rebuilt. Database dumps can be recreated
from the live database while it is healthy. User uploads have no second copy in
the base $0 architecture. Before accepting valuable uploads, decide and fund an
independent backup/retention policy or explicitly disclose that limitation.

## Drill schedule and evidence

Run a restore drill after schema changes and at least quarterly when meaningful
data exists. Record dump checksum/size (not secret contents), PostgreSQL version,
source/target schema revision, row/object validation, start/end time, failures,
and cleanup. Current status: **procedure written; no provider restore tested**.
