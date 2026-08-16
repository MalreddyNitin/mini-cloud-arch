#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: infra/cloudflare/r2-bootstrap.sh --bucket NAME [options]

Safe default: prints the proposed API requests. Nothing changes without --apply.

Options:
  --bucket NAME        Private R2 bucket name (required; default R2_BUCKET).
  --account-id ID      Cloudflare account ID (default CF_ACCOUNT_ID).
  --location HINT      apac|eeur|enam|weur|wnam|oc (default wnam).
  --cors-origin URL    Exact browser origin; configures GET/PUT/HEAD CORS.
  --apply              Create/check the Standard bucket and optional CORS rule.
  --help               Show this help.

With --apply, CLOUDFLARE_API_TOKEN must be an operator token scoped to Workers
R2 Storage Write for this account. The script does not create S3 access keys,
make the bucket public, enable Infrequent Access, or delete anything. It checks
the managed r2.dev URL and custom domains and fails if public access is enabled.
EOF
}

apply=false
bucket="${R2_BUCKET:-}"
account_id="${CF_ACCOUNT_ID:-}"
location=wnam
cors_origin=""

while (($#)); do
  case "$1" in
    --bucket) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; bucket="$2"; shift ;;
    --account-id) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; account_id="$2"; shift ;;
    --location) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; location="$2"; shift ;;
    --cors-origin) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; cors_origin="$2"; shift ;;
    --apply) apply=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$bucket" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$ ]] || { printf 'Bucket must be 3-63 lowercase letters, digits, or hyphens.\n' >&2; exit 2; }
[[ -n "$account_id" ]] || { printf '%s\n' '--account-id or CF_ACCOUNT_ID is required.' >&2; exit 2; }
[[ "$location" =~ ^(apac|eeur|enam|weur|wnam|oc)$ ]] || { printf 'Invalid location hint.\n' >&2; exit 2; }
if [[ -n "$cors_origin" && ! "$cors_origin" =~ ^https?://[^/]+(:[0-9]+)?$ ]]; then
  printf 'CORS origin must be scheme://host[:port] with no path.\n' >&2
  exit 2
fi

base_url="https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets"
bucket_body="$(printf '{"name":"%s","locationHint":"%s","storageClass":"Standard"}' "$bucket" "$location")"

printf 'Mode: %s\n' "$([[ "$apply" == true ]] && printf APPLY || printf DRY-RUN)"
printf '  POST %s\n' "$base_url"
printf '  body: %s\n' "$bucket_body"
if [[ -n "$cors_origin" ]]; then
  printf '  PUT %s/%s/cors (origin %s; GET, PUT, HEAD only)\n' "$base_url" "$bucket" "$cors_origin"
fi
printf '  GET %s/%s/domains/managed (require r2.dev disabled)\n' "$base_url" "$bucket"
printf '  GET %s/%s/domains/custom (require all custom domains disabled)\n' "$base_url" "$bucket"

if [[ "$apply" != true ]]; then
  printf 'No resources changed. Re-run with --apply after reviewing the requests.\n'
  exit 0
fi

command -v curl >/dev/null 2>&1 || { printf 'curl is required with --apply.\n' >&2; exit 1; }
python_bin=''
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
fi
token="${CLOUDFLARE_API_TOKEN:-}"
[[ -n "$token" ]] || { printf 'CLOUDFLARE_API_TOKEN is required with --apply.\n' >&2; exit 1; }

response_file="$(mktemp)"
cleanup() { rm -f -- "$response_file"; }
trap cleanup EXIT

status="$(curl --silent --show-error -o "$response_file" --write-out '%{http_code}' \
  -H "Authorization: Bearer $token" "$base_url/$bucket")"
if [[ "$status" == 200 ]]; then
  if grep -E '"storage_class"[[:space:]]*:[[:space:]]*"Standard"' "$response_file" >/dev/null; then
    printf 'Bucket exists and reports Standard storage.\n'
  else
    printf 'Existing bucket does not report Standard storage; refusing to continue.\n' >&2
    exit 1
  fi
elif [[ "$status" == 404 ]]; then
  curl --fail-with-body --silent --show-error -X POST "$base_url" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary "$bucket_body" -o "$response_file"
  grep -E '"success"[[:space:]]*:[[:space:]]*true' "$response_file" >/dev/null || {
    printf 'Cloudflare did not confirm bucket creation.\n' >&2
    exit 1
  }
  printf 'Created private Standard-class R2 bucket.\n'
else
  printf 'Unable to inspect bucket (HTTP %s).\n' "$status" >&2
  exit 1
fi

if [[ -n "$cors_origin" ]]; then
  cors_body="$(printf '{"rules":[{"id":"browser-direct-transfer","allowed":{"methods":["GET","PUT","HEAD"],"origins":["%s"],"headers":["Content-Type"]},"exposeHeaders":["ETag"],"maxAgeSeconds":3600}]}' "$cors_origin")"
  curl --fail-with-body --silent --show-error -X PUT "$base_url/$bucket/cors" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary "$cors_body" -o "$response_file"
  grep -E '"success"[[:space:]]*:[[:space:]]*true' "$response_file" >/dev/null || {
    printf 'Cloudflare did not confirm CORS configuration.\n' >&2
    exit 1
  }
  printf 'Configured exact-origin browser CORS. Propagation can take about 30 seconds.\n'
fi

check_public_endpoint() {
  local kind="$1"
  local endpoint="$2"
  local label="$3"
  local domain_status
  if ! domain_status="$(curl --silent --show-error -o "$response_file" --write-out '%{http_code}' \
      -H "Authorization: Bearer $token" "$endpoint")"; then
    printf 'WARNING: could not query %s public access; check it manually.\n' \
      "$label" >&2
    return 0
  fi
  if [[ "$domain_status" != 200 ]]; then
    printf 'WARNING: could not verify %s public access (HTTP %s); check it manually.\n' \
      "$label" "$domain_status" >&2
    return 0
  fi
  if [[ -z "$python_bin" ]]; then
    printf 'WARNING: Python is unavailable; check %s public access manually.\n' "$label" >&2
    return 0
  fi
  if "$python_bin" - "$response_file" "$kind" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
if payload.get("success") is not True:
    raise SystemExit(2)
result = payload.get("result") or {}
if sys.argv[2] == "managed":
    enabled = bool(result.get("enabled"))
    domains = [str(result.get("domain") or "r2.dev")] if enabled else []
else:
    entries = result.get("domains", []) if isinstance(result, dict) else []
    domains = [str(entry.get("domain") or "custom-domain") for entry in entries if entry.get("enabled")]
if domains:
    print(", ".join(domains), file=sys.stderr)
    raise SystemExit(3)
PY
  then
    printf 'Verified %s public access is disabled.\n' "$label"
  else
    case "$?" in
      3)
        printf 'ERROR: %s public access is enabled; disable it before using this private bucket.\n' \
          "$label" >&2
        exit 1
        ;;
      *)
        printf 'WARNING: could not parse %s public-access state; check it manually.\n' \
          "$label" >&2
        ;;
    esac
  fi
}

check_public_endpoint managed "$base_url/$bucket/domains/managed" 'r2.dev development URL'
check_public_endpoint custom "$base_url/$bucket/domains/custom" 'custom-domain'

printf 'No S3 credentials were created. Create a bucket-scoped token separately, resolve any public-access warnings, and run the full smoke test.\n'
