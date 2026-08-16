# Zero Cloud API

FastAPI + SQLAlchemy service for the local vertical slice and Cloud Run deployment. The
service is stateless in production: relational state belongs in Neon and object bytes move
directly between the client and private R2 using short-lived signed URLs.

## Local setup

From this directory:

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements-dev.lock  # Windows
alembic upgrade head
python -m app
```

The development default is a local SQLite database. PostgreSQL URLs supplied as
`postgres://` or `postgresql://` are normalized to the psycopg 3 driver. Production requires
PostgreSQL and should use Neon's pooled URL in `DATABASE_URL`; migrations prefer
`DATABASE_URL_DIRECT` when provided.
Production validation requires `sslmode=require`, `verify-ca`, or `verify-full` on both URLs.
Runtime PostgreSQL connections default to a 5-second connect timeout and a server-enforced
10-second statement timeout. `DB_CONNECT_TIMEOUT` is bounded to 1-10 seconds and
`DB_STATEMENT_TIMEOUT_MS` to 100-25,000 ms. In production, those values plus
`DB_POOL_TIMEOUT` must remain within a 28-second aggregate budget, below the Cloud Run request
timeout.

## Safety defaults

`GET /api/items`, `/health`, and `/ready` are public. All mutation and presign endpoints return
403 unless `ENABLE_WRITES=true`. Development/test may enable writes without a token. Production
validation requires a `WRITE_API_KEY` of at least 32 characters, supplied to API calls as a
Bearer token. A browser application must never embed this shared token; use real user
authentication or a trusted gateway before enabling public production writes.

R2 presigns require all of `R2_ENDPOINT_URL`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and
`R2_BUCKET`. Uploads are limited to 10 MiB by default and to the configured MIME allowlist.
The API chooses every object key and only signs downloads for keys matching that convention.
The declared byte size is included as signed `Content-Length`; the uploaded body must match it
exactly. Browsers derive this forbidden request header from the `Blob` body automatically, so
clients should not try to set it manually or use a chunked/streaming body.

Uvicorn's raw access logger is disabled. Request logs come only from the structured middleware,
which records route templates such as `/api/items/{item_id}`. Unmatched URLs are recorded as
`<unmatched>`, so object keys, filenames, query strings, and arbitrary path content are omitted.

## Checks

```bash
ruff check app tests migrations
mypy app
pytest --cov=app --cov-report=term-missing
alembic upgrade head
```
