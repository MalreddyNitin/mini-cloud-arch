#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-free-tier.sh [checks] [options]

Checks (default: --static):
  --static              Validate repository cost-safety invariants.
  --gcp                 Inspect the deployed Cloud Run configuration.
  --r2                  Query current-month R2 storage/operation analytics.
  --neon                Query PostgreSQL database size (CU-hours remain a
                        Neon dashboard check).
  --all                 Run every check.

Options:
  --project-id ID       Defaults to GCP_PROJECT_ID.
  --region REGION       Defaults to GCP_REGION or us-central1.
  --service NAME        Defaults to CLOUD_RUN_SERVICE_NAME or zero-cloud-api.
  --account-id ID       Defaults to CF_ACCOUNT_ID. R2 usage is always summed
                        account-wide because the allowance is account-wide.
  --help                Show this help.

Live R2 checks require CF_ANALYTICS_API_TOKEN (or CLOUDFLARE_API_TOKEN).
Live Neon checks require DATABASE_URL_DIRECT (or DATABASE_URL) and psql.
The script warns at 80% of documented free allowances and fails on unsafe
Cloud Run configuration or when a measured storage allowance is exceeded.
EOF
}

do_static=false
do_gcp=false
do_r2=false
do_neon=false
selected=false
project_id="${GCP_PROJECT_ID:-}"
region="${GCP_REGION:-us-central1}"
service="${CLOUD_RUN_SERVICE_NAME:-zero-cloud-api}"
account_id="${CF_ACCOUNT_ID:-}"

while (($#)); do
  case "$1" in
    --static) do_static=true; selected=true ;;
    --gcp) do_gcp=true; selected=true ;;
    --r2) do_r2=true; selected=true ;;
    --neon) do_neon=true; selected=true ;;
    --all) do_static=true; do_gcp=true; do_r2=true; do_neon=true; selected=true ;;
    --project-id) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; project_id="$2"; shift ;;
    --region) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; region="$2"; shift ;;
    --service) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; service="$2"; shift ;;
    --account-id) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; account_id="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$selected" == false ]]; then
  do_static=true
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
fi

failures=0
warnings=0
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

require_literal() {
  local file="$1"
  local value="$2"
  local description="$3"
  if grep -F -- "$value" "$file" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description ($value missing from $file)"
  fi
}

forbid_literal() {
  local file="$1"
  local value="$2"
  local description="$3"
  if grep -F -- "$value" "$file" >/dev/null 2>&1; then
    fail "$description ($value found in $file)"
  else
    pass "$description"
  fi
}

if [[ "$do_static" == true ]]; then
  printf '%s\n' '== Repository guardrails =='
  require_literal infra/gcp/deploy-cloud-run.sh '--min-instances 0' 'Cloud Run minimum instances are pinned to zero'
  require_literal infra/gcp/deploy-cloud-run.sh '--max-instances 1' 'Cloud Run maximum instances are pinned to one'
  require_literal infra/gcp/deploy-cloud-run.sh '--memory 512Mi' 'Cloud Run memory is pinned to 512 MiB'
  require_literal infra/gcp/deploy-cloud-run.sh '--timeout 30' 'Cloud Run timeout is pinned to 30 seconds'
  require_literal infra/gcp/deploy-cloud-run.sh '--cpu-throttling' 'Cloud Run request-based CPU throttling is explicit'
  require_literal infra/gcp/deploy-cloud-run.sh '--no-cpu-boost' 'Cloud Run startup CPU boost is disabled'
  require_literal infra/gcp/deploy-cloud-run.sh '--no-traffic' 'Cloud Run candidates receive no production traffic before smoke testing'
  require_literal infra/gcp/deploy-cloud-run.sh 'services update-traffic' 'Cloud Run promotion is an explicit post-smoke step'
  forbid_literal infra/gcp/deploy-cloud-run.sh '--allow-unauthenticated' 'Candidate deploy does not enable service-wide public IAM before smoke'
  forbid_literal infra/gcp/deploy-cloud-run.sh '--no-allow-unauthenticated' 'Candidate deploy does not revoke service-wide public IAM before smoke'
  require_literal infra/gcp/deploy-cloud-run.sh 'services add-iam-policy-binding' 'Public IAM is reconciled explicitly after promotion'
  require_literal infra/gcp/deploy-cloud-run.sh 'services remove-iam-policy-binding' 'Private IAM is reconciled explicitly after promotion'
  require_literal infra/gcp/deploy-cloud-run.sh 'trap cleanup_on_exit EXIT' 'Cloud Run candidate tags are cleaned on every post-deploy failure'
  require_literal .github/workflows/deploy-api.yml 'scripts/migration_gate.py' 'Production deploys enforce the migration attestation gate'
  require_literal .github/workflows/deploy-api.yml 'verify-production-migration.sh' 'Production deploys query the actual database revision read-only'
  require_literal .github/workflows/deploy-api.yml 'head_repository.full_name == github.repository' 'Privileged workflow_run deploys require the trusted repository'
  require_literal .github/workflows/deploy-api.yml "vars.ENABLE_PRODUCTION_DEPLOY == 'true'" 'Production deployment is opt-in until provider configuration is complete'
  forbid_literal .github/workflows/deploy-api.yml 'workflow_dispatch' 'Production deployment cannot bypass successful CI lineage'
  require_literal .github/workflows/deploy-api.yml 'Scan exact deployment candidate' 'The exact CD-built image is vulnerability scanned'
  require_literal scripts/check-free-tier.sh '10000000000' 'R2 storage guardrail uses the decimal 10 GB allowance'
  require_literal scripts/smoke-test.sh 'X-Serverless-Authorization' 'Smoke tests separate Cloud Run IAM from application authorization'
  require_literal scripts/smoke-test.sh 'plan_min_r2_bytes=$((10 * 1024 * 1024))' 'Full R2 smoke defaults to the 10 MiB acceptance payload'
  require_literal scripts/backup-db.sh '--metadata "sha256=$dump_sha256"' 'R2 database backups record local SHA-256 metadata'
  require_literal scripts/backup-db.sh 'verify_backup_metadata.py' 'R2 database backups verify remote size and SHA-256 metadata'
  require_literal infra/gcp/bootstrap.sh 'billingbudgets.googleapis.com' 'GCP bootstrap enables the Budget API before budget creation'

  if grep -R -E -- '(credentials_json|GOOGLE_CREDENTIALS|service[_-]?account.*\.json)' .github/workflows infra/gcp >/dev/null 2>&1; then
    fail 'long-lived Google credential pattern found in deployment configuration'
  else
    pass 'deployment configuration has no long-lived Google key input'
  fi

  tracked_env="$(git ls-files 2>/dev/null | grep -E '(^|/)\.env($|\.)' | grep -v -E '(^|/)\.env\.example$' || true)"
  if [[ -n "$tracked_env" ]]; then
    fail "tracked environment file(s): $tracked_env"
  else
    pass 'no secret-bearing .env file is tracked'
  fi

  if git grep -I -E -- 'AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' -- . \
      ':(exclude)docs/security.md' >/dev/null 2>&1; then
    fail 'probable credential material found in tracked content'
  else
    pass 'no common private-key/token signature found in tracked content'
  fi
fi

if [[ "$do_gcp" == true ]]; then
  printf '%s\n' '== Cloud Run live configuration =='
  command -v gcloud >/dev/null 2>&1 || { fail 'gcloud is required for --gcp'; do_gcp=false; }
  [[ -n "$project_id" ]] || { fail 'GCP project ID is required for --gcp'; do_gcp=false; }
fi

if [[ "$do_gcp" == true ]]; then
  [[ -n "$python_bin" ]] || { fail 'Python is required to parse Cloud Run configuration'; do_gcp=false; }
fi

if [[ "$do_gcp" == true ]]; then
  config_file="$(mktemp)"
  if gcloud run services describe "$service" --project "$project_id" --region "$region" --format=json >"$config_file"; then
    if "$python_bin" - "$config_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
spec = data.get("spec", {})
template = spec.get("template", {})
metadata = template.get("metadata", {})
annotations = metadata.get("annotations", {}) or {}
template_spec = template.get("spec", {})
scaling = template.get("scaling", {}) or {}
containers = template_spec.get("containers", []) or template.get("containers", []) or []
container = containers[0] if containers else {}
limits = (container.get("resources", {}) or {}).get("limits", {}) or {}

def first(*values):
    return next((v for v in values if v is not None and v != ""), None)

minimum = first(scaling.get("minInstanceCount"), annotations.get("autoscaling.knative.dev/minScale"), 0)
maximum = first(scaling.get("maxInstanceCount"), annotations.get("autoscaling.knative.dev/maxScale"))
memory = limits.get("memory")
cpu = limits.get("cpu")
concurrency = first(template_spec.get("containerConcurrency"), template.get("maxInstanceRequestConcurrency"))
timeout = first(template_spec.get("timeoutSeconds"), template.get("timeout"))
cpu_idle = first(template.get("containers", [{}])[0].get("resources", {}).get("cpuIdle") if template.get("containers") else None,
                 annotations.get("run.googleapis.com/cpu-throttling"))
startup_boost = first(
    (container.get("resources", {}) or {}).get("startupCpuBoost"),
    annotations.get("run.googleapis.com/startup-cpu-boost"),
)

observed = {
    "min_instances": str(minimum),
    "max_instances": str(maximum),
    "memory": str(memory),
    "cpu": str(cpu),
    "concurrency": str(concurrency),
    "timeout": str(timeout),
    "cpu_idle_or_throttling": str(cpu_idle),
    "startup_cpu_boost": str(startup_boost),
}
print("Observed: " + ", ".join(f"{k}={v}" for k, v in observed.items()))

ok = True
ok &= str(minimum) in {"0", "0.0"}
ok &= str(maximum) in {"1", "1.0"}
ok &= str(memory).lower() in {"512mi", "512m", "0.5gi"}
ok &= str(cpu) in {"1", "1000m"}
ok &= str(concurrency) in {"80", "80.0"}
ok &= str(timeout).rstrip("s") == "30"
ok &= cpu_idle is not None and str(cpu_idle).lower() in {"true", "1"}
ok &= startup_boost is not None and str(startup_boost).lower() in {"false", "0"}
raise SystemExit(0 if ok else 1)
PY
    then
      pass 'deployed Cloud Run service matches the cost-safe envelope'
    else
      fail 'deployed Cloud Run service is outside the cost-safe envelope'
    fi
  else
    fail 'unable to describe the Cloud Run service (it may not be provisioned)'
  fi
  rm -f -- "$config_file"
fi

if [[ "$do_r2" == true ]]; then
  printf '%s\n' '== R2 current-month analytics =='
  analytics_token="${CF_ANALYTICS_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
  command -v curl >/dev/null 2>&1 || { fail 'curl is required for --r2'; do_r2=false; }
  [[ -n "$python_bin" ]] || { fail 'Python is required for --r2'; do_r2=false; }
  [[ -n "$account_id" ]] || { fail 'CF_ACCOUNT_ID is required for --r2'; do_r2=false; }
  [[ -n "$analytics_token" ]] || { fail 'CF_ANALYTICS_API_TOKEN or CLOUDFLARE_API_TOKEN is required for --r2'; do_r2=false; }
fi

if [[ "$do_r2" == true ]]; then
  request_file="$(mktemp)"
  response_file="$(mktemp)"
  "$python_bin" - "$request_file" "$account_id" <<'PY'
import datetime as dt
import json
import sys

now = dt.datetime.now(dt.timezone.utc)
start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
query = r'''query R2Usage($accountTag: string!, $startDate: Time!, $endDate: Time!) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      operations: r2OperationsAdaptiveGroups(limit: 10000, filter: {datetime_geq: $startDate, datetime_leq: $endDate}) {
        sum { requests }
        dimensions { actionType bucketName }
      }
      storage: r2StorageAdaptiveGroups(limit: 10000, filter: {datetime_geq: $startDate, datetime_leq: $endDate}, orderBy: [datetime_DESC]) {
        max { objectCount uploadCount payloadSize metadataSize }
        dimensions { datetime bucketName }
      }
    }
  }
}'''
payload = {
    "query": query,
    "variables": {
        "accountTag": sys.argv[2],
        "startDate": start.isoformat().replace("+00:00", "Z"),
        "endDate": now.isoformat().replace("+00:00", "Z"),
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  if curl --fail-with-body --silent --show-error \
      -H "Authorization: Bearer $analytics_token" -H 'Content-Type: application/json' \
      --data-binary @"$request_file" https://api.cloudflare.com/client/v4/graphql \
      -o "$response_file"; then
    r2_summary="$("$python_bin" "$repo_root/scripts/r2_usage.py" "$response_file")" || {
      fail 'unable to parse R2 analytics response'
      r2_summary=''
    }
    if [[ -n "$r2_summary" ]]; then
      printf '%s\n' "$r2_summary"
      storage_bytes="$(printf '%s\n' "$r2_summary" | sed -n 's/^storage_bytes=//p')"
      class_a="$(printf '%s\n' "$r2_summary" | sed -n 's/^class_a=//p')"
      class_b="$(printf '%s\n' "$r2_summary" | sed -n 's/^class_b=//p')"
      unknown_ops="$(printf '%s\n' "$r2_summary" | sed -n 's/^unknown_ops=//p')"
      analytics_rows_at_limit="$(printf '%s\n' "$r2_summary" | sed -n 's/^analytics_rows_at_limit=//p')"
      if ((storage_bytes > 10000000000)); then fail 'R2 storage exceeds 10 GB';
      elif ((storage_bytes > 8000000000)); then warn 'R2 storage exceeds the 80% warning threshold';
      else pass 'R2 storage is below the 80% warning threshold'; fi
      if ((class_a > 1000000)); then fail 'known R2 Class A operations exceed 1 million';
      elif ((class_a > 800000)); then warn 'known R2 Class A operations exceed the 80% warning threshold';
      else pass 'known R2 Class A operations are below the 80% warning threshold'; fi
      if ((class_b > 10000000)); then fail 'known R2 Class B operations exceed 10 million';
      elif ((class_b > 8000000)); then warn 'known R2 Class B operations exceed the 80% warning threshold';
      else pass 'known R2 Class B operations are below the 80% warning threshold'; fi
      if ((unknown_ops > 0)); then warn 'unknown R2 action types require classification against the current pricing table'; fi
      if ((analytics_rows_at_limit > 0)); then fail 'R2 analytics reached the 10,000-row query limit; totals may be truncated'; fi
    fi
  else
    fail 'R2 analytics query failed'
  fi
  rm -f -- "$request_file" "$response_file"
fi

if [[ "$do_neon" == true ]]; then
  printf '%s\n' '== Neon database storage =='
  database_url="${DATABASE_URL_DIRECT:-${DATABASE_URL:-}}"
  command -v psql >/dev/null 2>&1 || { fail 'psql is required for --neon'; do_neon=false; }
  [[ -n "$database_url" ]] || { fail 'DATABASE_URL_DIRECT or DATABASE_URL is required for --neon'; do_neon=false; }
fi

if [[ "$do_neon" == true ]]; then
  psql_url="${database_url/postgresql+psycopg:/postgresql:}"
  if database_bytes="$(PGDATABASE="$psql_url" psql -X -v ON_ERROR_STOP=1 -Atc 'SELECT pg_database_size(current_database())')"; then
    printf 'database_bytes=%s\n' "$database_bytes"
    if ((database_bytes > 500000000)); then fail 'Neon database exceeds 0.5 GB';
    elif ((database_bytes > 400000000)); then warn 'Neon database exceeds the 80% storage warning threshold';
    else pass 'Neon database is below the 80% storage warning threshold'; fi
    warn 'Neon CU-hours cannot be derived from SQL; verify current-month CU-hours in the Neon dashboard'
  else
    fail 'unable to query Neon database size'
  fi
fi

printf 'Summary: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
((failures == 0))
