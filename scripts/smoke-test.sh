#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/smoke-test.sh --api-url URL [options]

Options:
  --web-url URL          Also verify the static frontend responds.
  --mutations            Exercise item create/read/delete.
  --r2                   Exercise a 10 MiB+ presigned direct PUT/GET and cleanup.
  --full                 Equivalent to --mutations --r2.
  --r2-size-bytes N      R2 payload size, 10-100 MiB (default: 10485760). It
                          must not exceed MAX_UPLOAD_BYTES (default: 10485760).
  --write-api-key VALUE  Bearer key for protected write endpoints. Prefer the
                         SMOKE_WRITE_API_KEY environment variable.
  --cloud-run-token VAL  Identity token for private Cloud Run. It uses
                         X-Serverless-Authorization and can be combined with
                         the application write key.
  --timeout SECONDS      Per-request timeout (default: 30).
  -h, --help             Show this help.

R2 cleanup requires aws CLI plus R2_ENDPOINT_URL, R2_BUCKET,
R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY. URLs and tokens are never printed.
EOF
}

api_url="${API_URL:-}"
web_url="${WEB_URL:-}"
write_api_key="${SMOKE_WRITE_API_KEY:-}"
cloud_run_token="${SMOKE_CLOUD_RUN_TOKEN:-}"
timeout_seconds=30
mutations=false
r2=false
plan_min_r2_bytes=$((10 * 1024 * 1024))
hard_max_r2_bytes=$((100 * 1024 * 1024))
r2_size_bytes="${SMOKE_R2_SIZE_BYTES:-$plan_min_r2_bytes}"
app_max_upload_bytes="${MAX_UPLOAD_BYTES:-$plan_min_r2_bytes}"

while (($#)); do
  case "$1" in
    --api-url) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; api_url="$2"; shift ;;
    --web-url) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; web_url="$2"; shift ;;
    --mutations) mutations=true ;;
    --r2) r2=true; mutations=true ;;
    --full) r2=true; mutations=true ;;
    --r2-size-bytes) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; r2_size_bytes="$2"; shift ;;
    --write-api-key) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; write_api_key="$2"; shift ;;
    --cloud-run-token) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; cloud_run_token="$2"; shift ;;
    --timeout) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; timeout_seconds="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$api_url" ]] || { printf '%s\n' '--api-url is required.' >&2; usage >&2; exit 2; }
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { printf 'timeout must be a positive integer.\n' >&2; exit 2; }
[[ "$app_max_upload_bytes" =~ ^[1-9][0-9]*$ ]] || { printf 'MAX_UPLOAD_BYTES must be a positive integer.\n' >&2; exit 2; }
if [[ "$r2" == true ]]; then
  [[ "$r2_size_bytes" =~ ^[1-9][0-9]*$ ]] || { printf 'R2 payload size must be a positive integer.\n' >&2; exit 2; }
  if ((r2_size_bytes < plan_min_r2_bytes || r2_size_bytes > hard_max_r2_bytes)); then
    printf 'R2 payload size must be between 10 MiB and 100 MiB.\n' >&2
    exit 2
  fi
  if ((r2_size_bytes > app_max_upload_bytes)); then
    printf 'R2 payload size (%s) exceeds MAX_UPLOAD_BYTES (%s).\n' \
      "$r2_size_bytes" "$app_max_upload_bytes" >&2
    exit 2
  fi
fi
api_url="${api_url%/}"
web_url="${web_url%/}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v curl >/dev/null 2>&1 || { printf 'curl is required.\n' >&2; exit 1; }
python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  printf 'Python is required for safe JSON parsing.\n' >&2
  exit 1
fi

curl_common=(--fail-with-body --silent --show-error --connect-timeout 10 --max-time "$timeout_seconds")
curl_read=("${curl_common[@]}" --retry 2 --retry-all-errors)
read_auth=()
write_auth=()
if [[ -n "$cloud_run_token" ]]; then
  read_auth=(-H "X-Serverless-Authorization: Bearer $cloud_run_token")
  write_auth=(-H "X-Serverless-Authorization: Bearer $cloud_run_token")
fi
if [[ -n "$write_api_key" ]]; then
  write_auth+=(-H "Authorization: Bearer $write_api_key")
fi

tmp_dir="$(mktemp -d)"
item_id=""
object_key=""

urlencode_path() {
  "$python_bin" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$1"
}

json_field() {
  local file="$1"
  local field="$2"
  "$python_bin" "$repo_root/scripts/json_field.py" "$file" "$field"
}

cleanup() {
  local rc=$?
  set +e
  if [[ -n "$object_key" ]]; then
    AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}" \
      AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}" \
      AWS_DEFAULT_REGION=auto \
      aws --endpoint-url "${R2_ENDPOINT_URL:-}" s3api delete-object \
        --bucket "${R2_BUCKET:-}" --key "$object_key" >/dev/null
    if [[ $? -ne 0 ]]; then
      printf 'ERROR: failed to remove smoke-test object from R2. Key: %s\n' "$object_key" >&2
      rc=1
    else
      printf 'PASS: R2 smoke object cleanup\n'
    fi
  fi
  if [[ -n "$item_id" ]]; then
    curl "${curl_common[@]}" "${write_auth[@]}" -X DELETE "$api_url/api/items/$item_id" >/dev/null
    if [[ $? -ne 0 ]]; then
      printf 'ERROR: failed to remove smoke-test database item: %s\n' "$item_id" >&2
      rc=1
    else
      printf 'PASS: database smoke item cleanup\n'
    fi
  fi
  rm -rf -- "$tmp_dir"
  exit "$rc"
}
trap cleanup EXIT INT TERM

if [[ -n "$web_url" ]]; then
  curl "${curl_read[@]}" "$web_url/" -o /dev/null
  printf 'PASS: frontend responds\n'
fi

curl "${curl_read[@]}" "${read_auth[@]}" "$api_url/health" -o "$tmp_dir/health.json"
[[ "$(json_field "$tmp_dir/health.json" status)" == "ok" ]] || { printf 'Unexpected /health payload.\n' >&2; exit 1; }
printf 'PASS: API process health\n'

curl "${curl_read[@]}" "${read_auth[@]}" "$api_url/ready" -o "$tmp_dir/ready.json"
[[ "$(json_field "$tmp_dir/ready.json" status)" == "ready" ]] || { printf 'Unexpected /ready payload.\n' >&2; exit 1; }
printf 'PASS: API database readiness\n'

curl "${curl_read[@]}" "${read_auth[@]}" "$api_url/api/items?limit=1&offset=0" -o "$tmp_dir/items.json"
"$python_bin" -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); assert isinstance(data.get("items"), list); assert isinstance(data.get("total"), int)' "$tmp_dir/items.json"
printf 'PASS: bounded item read\n'

if [[ "$mutations" == true ]]; then
  unique_name="smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  printf '{"name":"%s"}' "$unique_name" >"$tmp_dir/create.json"
  curl "${curl_common[@]}" "${write_auth[@]}" -X POST \
    -H 'Content-Type: application/json' --data-binary @"$tmp_dir/create.json" \
    "$api_url/api/items" -o "$tmp_dir/item.json"
  item_id="$(json_field "$tmp_dir/item.json" id)"
  [[ -n "$item_id" ]] || { printf 'Item create response had no id.\n' >&2; exit 1; }
  curl "${curl_read[@]}" "${read_auth[@]}" "$api_url/api/items?limit=100&offset=0" -o "$tmp_dir/items-after.json"
  "$python_bin" -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); assert any(x.get("id") == sys.argv[2] for x in data["items"])' "$tmp_dir/items-after.json" "$item_id"
  printf 'PASS: database create/read round trip\n'
fi

if [[ "$r2" == true ]]; then
  command -v aws >/dev/null 2>&1 || { printf 'aws CLI is required for guaranteed R2 cleanup.\n' >&2; exit 1; }
  for required in R2_ENDPOINT_URL R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
    [[ -n "${!required:-}" ]] || { printf '%s is required for --r2.\n' "$required" >&2; exit 1; }
  done

  "$python_bin" - "$tmp_dir/upload.bin" "$r2_size_bytes" <<'PY'
import sys

path = sys.argv[1]
size = int(sys.argv[2])
with open(path, "wb") as handle:
    handle.truncate(size)
PY
  upload_size="$(wc -c <"$tmp_dir/upload.bin" | tr -d '[:space:]')"
  [[ "$upload_size" == "$r2_size_bytes" ]] || { printf 'Unable to create the requested R2 smoke payload.\n' >&2; exit 1; }
  printf 'Testing browser-direct R2 transfer with %s bytes.\n' "$upload_size"
  printf '{"filename":"smoke.txt","content_type":"text/plain","size_bytes":%s}' "$upload_size" >"$tmp_dir/presign-request.json"
  curl "${curl_common[@]}" "${write_auth[@]}" -X POST \
    -H 'Content-Type: application/json' --data-binary @"$tmp_dir/presign-request.json" \
    "$api_url/api/files/presign-upload" -o "$tmp_dir/presign-upload.json"
  upload_url="$(json_field "$tmp_dir/presign-upload.json" upload_url)"
  object_key="$(json_field "$tmp_dir/presign-upload.json" key)"
  [[ -n "$upload_url" && -n "$object_key" ]] || { printf 'Upload presign response is incomplete.\n' >&2; exit 1; }

  curl "${curl_common[@]}" -X PUT -H 'Content-Type: text/plain' \
    --data-binary @"$tmp_dir/upload.bin" "$upload_url" -o /dev/null
  printf 'PASS: browser-style direct R2 upload\n'

  encoded_key="$(urlencode_path "$object_key")"
  curl "${curl_read[@]}" "${write_auth[@]}" \
    "$api_url/api/files/$encoded_key/presign-download" -o "$tmp_dir/presign-download.json"
  download_url="$(json_field "$tmp_dir/presign-download.json" download_url)"
  curl "${curl_read[@]}" "$download_url" -o "$tmp_dir/download.bin"
  cmp "$tmp_dir/upload.bin" "$tmp_dir/download.bin"
  printf 'PASS: browser-style direct R2 download\n'
fi

printf 'Smoke test passed.\n'
