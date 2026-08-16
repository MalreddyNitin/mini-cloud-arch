#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-production-migration.sh --expected REVISION

Read-only production gate. Requires DATABASE_URL_DIRECT in the environment and
psql. It queries only Alembic's version table and never applies a migration.
The URL must require TLS and is never printed.
EOF
}

expected=''
while (($#)); do
  case "$1" in
    --expected) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; expected="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$expected" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  printf 'A valid --expected Alembic revision is required.\n' >&2
  exit 2
}
database_url="${DATABASE_URL_DIRECT:-}"
[[ -n "$database_url" ]] || {
  printf 'DATABASE_URL_DIRECT is required in the environment.\n' >&2
  exit 1
}
command -v psql >/dev/null 2>&1 || {
  printf 'psql is required for the read-only production migration gate.\n' >&2
  exit 1
}

psql_url="${database_url/postgresql+psycopg:/postgresql:}"
[[ "$psql_url" =~ ^postgres(ql)?:// ]] || {
  printf 'DATABASE_URL_DIRECT must be a PostgreSQL URL.\n' >&2
  exit 1
}
tls_pattern='[?&]sslmode=(require|verify-ca|verify-full)($|&)'
[[ "$psql_url" =~ $tls_pattern ]] || {
  printf 'DATABASE_URL_DIRECT must explicitly require TLS with sslmode.\n' >&2
  exit 1
}

query='SELECT version_num FROM public.alembic_version ORDER BY version_num'
if ! output="$(PGCONNECT_TIMEOUT=10 PGOPTIONS='-c statement_timeout=10000' \
    PGDATABASE="$psql_url" psql -X --no-password --set ON_ERROR_STOP=1 \
    --tuples-only --no-align --command "$query")"; then
  printf 'Unable to read the production Alembic revision. No migration was run.\n' >&2
  exit 1
fi

revisions=()
while IFS= read -r revision; do
  revision="${revision//[[:space:]]/}"
  [[ -n "$revision" ]] && revisions+=("$revision")
done <<<"$output"

if ((${#revisions[@]} != 1)); then
  printf 'Production must report exactly one Alembic revision; found %d.\n' \
    "${#revisions[@]}" >&2
  exit 1
fi
if [[ "${revisions[0]}" != "$expected" ]]; then
  printf 'Production Alembic revision does not match the approved repository head.\n' >&2
  printf 'Expected: %s; observed: %s\n' "$expected" "${revisions[0]}" >&2
  exit 1
fi

printf 'Production database migration gate passed at revision %s (read-only query).\n' \
  "$expected"
