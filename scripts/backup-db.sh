#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/backup-db.sh [options]

Options:
  --output-dir DIR    Local destination (default: backups/db).
  --upload-r2         Upload the compressed custom-format dump to R2.
  --delete-local      Remove the local dump only after a verified R2 upload.
  --help              Show this help.

Uses DATABASE_URL_DIRECT, falling back to DATABASE_URL. R2 upload requires aws
CLI and R2_ENDPOINT_URL, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY.
An R2 copy records SHA-256 object metadata and must match the local size and
checksum before success or local deletion. No retention deletion is automatic.
EOF
}

output_dir=backups/db
upload_r2=false
delete_local=false
while (($#)); do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; output_dir="$2"; shift ;;
    --upload-r2) upload_r2=true ;;
    --delete-local) delete_local=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$delete_local" == true && "$upload_r2" != true ]]; then
  printf '%s\n' '--delete-local requires --upload-r2.' >&2
  exit 2
fi

database_url="${DATABASE_URL_DIRECT:-${DATABASE_URL:-}}"
[[ -n "$database_url" ]] || { printf 'DATABASE_URL_DIRECT or DATABASE_URL is required.\n' >&2; exit 1; }
command -v pg_dump >/dev/null 2>&1 || { printf 'pg_dump is required.\n' >&2; exit 1; }
command -v pg_restore >/dev/null 2>&1 || { printf 'pg_restore is required for dump verification.\n' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  sha256_command=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  sha256_command=(shasum -a 256)
else
  printf 'sha256sum or shasum is required for backup evidence.\n' >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$output_dir" != /* && ! "$output_dir" =~ ^[A-Za-z]:[/\\] ]]; then
  output_dir="$repo_root/$output_dir"
fi
mkdir -p -- "$output_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
dump_name="zero-cloud-${timestamp}.dump"
dump_path="$output_dir/$dump_name"
psql_url="${database_url/postgresql+psycopg:/postgresql:}"

printf 'Creating a compressed logical backup...\n'
PGDATABASE="$psql_url" pg_dump --format=custom --compress=9 --no-owner --no-acl --file="$dump_path"
pg_restore --list "$dump_path" >/dev/null
read -r dump_sha256 _ < <("${sha256_command[@]}" "$dump_path")
dump_size="$(wc -c <"$dump_path" | tr -d '[:space:]')"
[[ "$dump_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || { printf 'Unable to calculate a valid SHA-256 checksum.\n' >&2; exit 1; }
[[ "$dump_size" =~ ^[0-9]+$ ]] || { printf 'Unable to calculate the dump size.\n' >&2; exit 1; }
dump_sha256="${dump_sha256,,}"
printf 'Verified local dump: %s\n' "$dump_path"
printf 'Backup evidence: size_bytes=%s sha256=%s\n' "$dump_size" "$dump_sha256"

if [[ "$upload_r2" == true ]]; then
  command -v aws >/dev/null 2>&1 || { printf 'aws CLI is required for --upload-r2.\n' >&2; exit 1; }
  python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin=python3
  elif command -v python >/dev/null 2>&1; then
    python_bin=python
  else
    printf 'Python 3 is required to verify R2 object metadata.\n' >&2
    exit 1
  fi
  for required in R2_ENDPOINT_URL R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    [[ -n "${!required:-}" ]] || { printf '%s is required for --upload-r2.\n' "$required" >&2; exit 1; }
  done
  year="${timestamp:0:4}"
  month="${timestamp:4:2}"
  day="${timestamp:6:2}"
  object_key="backups/db/$year/$month/$day/$dump_name"
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
    aws --endpoint-url "$R2_ENDPOINT_URL" s3 cp "$dump_path" "s3://$R2_BUCKET/$object_key" \
      --metadata "sha256=$dump_sha256" --only-show-errors
  head_object_file="$(mktemp)"
  cleanup_head_object() { rm -f -- "$head_object_file"; }
  trap cleanup_head_object EXIT
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
    aws --endpoint-url "$R2_ENDPOINT_URL" s3api head-object \
      --bucket "$R2_BUCKET" --key "$object_key" >"$head_object_file"
  "$python_bin" "$repo_root/scripts/verify_backup_metadata.py" "$head_object_file" \
    --expected-size "$dump_size" --expected-sha256 "$dump_sha256"
  printf 'Verified R2 object bytes and SHA-256 metadata: r2://%s/%s\n' "$R2_BUCKET" "$object_key"
  if [[ "$delete_local" == true ]]; then
    rm -f -- "$dump_path"
    printf 'Removed local dump after verified upload.\n'
  fi
fi
