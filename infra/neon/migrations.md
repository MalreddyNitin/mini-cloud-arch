# Neon provisioning and migrations

Status: **not provisioned by this repository**. Neon account, project, branch,
credentials, and MFA must be created/verified by an authorized operator.

## Connection contract

- Use the pooled Neon URL for `DATABASE_URL` at runtime.
- Use the privileged direct/unpooled `DATABASE_URL_DIRECT` only for serialized
  operator migrations and backups. The migration configuration falls back to
  `DATABASE_URL`.
- Give CD a different direct-endpoint URL whose dedicated database role has only
  `CONNECT`, schema `USAGE`, and `SELECT` on `alembic_version`. Store that URL in
  the pinned `DATABASE_URL_DIRECT_SECRET`; never give CD the migration-owner URL.
- Require TLS (`sslmode=require`) in both URLs.
- Keep the runtime SQLAlchemy pool deliberately small (`DB_POOL_SIZE=2`,
  `DB_MAX_OVERFLOW=0`) while Cloud Run is capped at one instance.
- Bound initial connection setup to five seconds (`DB_CONNECT_TIMEOUT=5`) and
  each database statement to ten seconds (`DB_STATEMENT_TIMEOUT_MS=10000`).
- Never store these URLs in GitHub, Pages, image layers, shell history, or docs.

## Initial procedure

1. Create one Free-plan Neon project and a production database/role in the Neon
   console. Turn on MFA and record ownership/recovery contacts.
2. Copy pooled/direct URLs into an untracked operator environment.
3. Inspect the migration SQL before applying it:

   ```bash
   cd apps/api
   alembic upgrade head --sql > /tmp/zero-cloud-migration.sql
   ```

4. Apply the backward-compatible migration once, from a controlled operator
   shell—not concurrently in every Cloud Run instance:

   ```bash
   cd apps/api
   DATABASE_URL_DIRECT="$DATABASE_URL_DIRECT" alembic upgrade head
   alembic current
   ```

   After the initial table exists, create a separate verifier role and grant it
   only database `CONNECT`, schema `USAGE`, and `SELECT` on
   `public.alembic_version`. Use Neon's generated TLS-required direct URL for
   that role as the CD verification secret. Do not grant it DDL or data-table
   privileges.

5. Confirm the applied revision equals the repository's single head. Only after
   this succeeds, update the protected GitHub `production` environment variable
   `PRODUCTION_MIGRATION_REVISION` to that exact revision:

   ```bash
   cd apps/api
   alembic current
   alembic heads
   ```

   The deploy workflow first checks this marker against the repository graph,
   then uses a pinned direct-URL Secret Manager version to query the actual
   production `alembic_version`. It refuses release on a stale/missing marker,
   multiple heads/rows, a database error, or a mismatch. Never update the marker
   before the production migration completes and is verified.
6. Run `/ready`, CRUD smoke tests with writes explicitly protected/enabled, and
   inspect active connections. Disable writes again if the production workload
   is the default public read-only application.
7. Check database storage and current-month CU-hours in the Neon dashboard.

CI applies migrations to disposable PostgreSQL and runs `alembic check`. CD
does not automatically mutate production schema; its marker and read-only
database checks are a fail-closed release gate after the separate operator
action. Use
expand/migrate/contract: add compatible schema first, deploy compatible code,
backfill in a bounded operator task, and remove deprecated schema only in a
later release.

The logical backup/restore procedure is in
[`docs/disaster-recovery.md`](../../docs/disaster-recovery.md).
