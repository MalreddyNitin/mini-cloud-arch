#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: infra/gcp/deploy-cloud-run.sh --image IMAGE [options]

Safe default: prints the proposed deployment. Nothing changes without --apply.

Options:
  --image IMAGE          Immutable Artifact Registry image URI (required).
  --project-id ID        Defaults to GCP_PROJECT_ID.
  --region REGION        Defaults to GCP_REGION or us-central1.
  --service NAME         Defaults to CLOUD_RUN_SERVICE_NAME or zero-cloud-api.
  --candidate-tag TAG    Zero-traffic revision tag (default: candidate).
  --runtime-sa EMAIL     Defaults to cloud-run-runtime@PROJECT.iam.gserviceaccount.com.
  --app-origin ORIGIN    Exact frontend origin for CORS (required with --public).
  --r2-endpoint URL      Non-secret R2 S3 endpoint.
  --r2-bucket NAME       Non-secret private R2 bucket name.
  --secret ENV=NAME:VER  Bind a Secret Manager version. Repeatable; supported
                         ENV names are DATABASE_URL, R2_ACCESS_KEY_ID,
                         R2_SECRET_ACCESS_KEY, and WRITE_API_KEY. VER must be
                         numeric so a revision is reproducible.
  --public               Allow unauthenticated network access. Application
                         mutations still remain disabled by default. Service
                         IAM changes only after candidate smoke and promotion.
  --enable-writes        Set ENABLE_WRITES=true. Production startup still
                         requires a >=32-character server-side WRITE_API_KEY.
  --apply                Deploy at zero traffic, smoke test, then promote.
  --help                 Show this help.

The cost envelope is intentionally not configurable here: request-based CPU,
min 0, max 1, 1 CPU, 512 MiB, concurrency 80, timeout 30 seconds.
EOF
}

apply=false
public=false
enable_writes=false
image="${IMAGE_URI:-}"
project_id="${GCP_PROJECT_ID:-}"
region="${GCP_REGION:-us-central1}"
service="${CLOUD_RUN_SERVICE_NAME:-zero-cloud-api}"
candidate_tag="${CLOUD_RUN_CANDIDATE_TAG:-candidate}"
runtime_sa="${CLOUD_RUN_RUNTIME_SERVICE_ACCOUNT:-}"
app_origin="${APP_ORIGIN:-}"
r2_endpoint="${R2_ENDPOINT_URL:-}"
r2_bucket="${R2_BUCKET:-}"
secret_bindings=()

while (($#)); do
  case "$1" in
    --image) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; image="$2"; shift ;;
    --project-id) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; project_id="$2"; shift ;;
    --region) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; region="$2"; shift ;;
    --service) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; service="$2"; shift ;;
    --candidate-tag) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; candidate_tag="$2"; shift ;;
    --runtime-sa) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; runtime_sa="$2"; shift ;;
    --app-origin) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; app_origin="$2"; shift ;;
    --r2-endpoint) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; r2_endpoint="$2"; shift ;;
    --r2-bucket) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; r2_bucket="$2"; shift ;;
    --secret) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; secret_bindings+=("$2"); shift ;;
    --public) public=true ;;
    --enable-writes) enable_writes=true ;;
    --apply) apply=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$image" && "$image" != *[[:space:]]* ]] || { printf 'A valid --image is required.\n' >&2; exit 2; }
[[ -n "$project_id" ]] || { printf '%s\n' '--project-id or GCP_PROJECT_ID is required.' >&2; exit 2; }
[[ "$region" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || { printf 'Invalid region.\n' >&2; exit 2; }
[[ "$service" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || { printf 'Invalid service name.\n' >&2; exit 2; }
[[ "$candidate_tag" =~ ^[a-z]$|^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || {
  printf 'Invalid candidate tag. Use 1-63 lowercase letters, digits, or hyphens.\n' >&2
  exit 2
}
if [[ "$public" == true ]]; then
  [[ "$app_origin" =~ ^https://[^/]+(:[0-9]+)?$ ]] || {
    printf '%s\n' '--public requires an exact HTTPS --app-origin without a path.' >&2
    exit 2
  }
fi
[[ -n "$runtime_sa" ]] || runtime_sa="cloud-run-runtime@$project_id.iam.gserviceaccount.com"

for binding in "${secret_bindings[@]}"; do
  [[ "$binding" =~ ^(DATABASE_URL|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY|WRITE_API_KEY)=[a-zA-Z][a-zA-Z0-9_-]{0,254}:[1-9][0-9]*$ ]] || {
    printf 'Invalid --secret binding: %s\n' "$binding" >&2
    exit 2
  }
done

env_updates='APP_ENV=production,ENABLE_WRITES=false,DB_POOL_SIZE=2,DB_MAX_OVERFLOW=0,DB_CONNECT_TIMEOUT=5,DB_STATEMENT_TIMEOUT_MS=10000'
if [[ "$enable_writes" == true ]]; then
  env_updates='APP_ENV=production,ENABLE_WRITES=true,DB_POOL_SIZE=2,DB_MAX_OVERFLOW=0,DB_CONNECT_TIMEOUT=5,DB_STATEMENT_TIMEOUT_MS=10000'
  printf 'CAUTION: writes requested. Confirm WRITE_API_KEY is a server-side secret and is never shipped to the browser.\n' >&2
fi
if [[ -n "$app_origin" ]]; then
  env_updates="$env_updates,APP_ORIGIN=$app_origin,CORS_ORIGINS=$app_origin"
fi
if [[ -n "$r2_endpoint" ]]; then
  [[ "$r2_endpoint" =~ ^https://[^/]+\.r2\.cloudflarestorage\.com$ ]] || { printf 'Invalid R2 endpoint.\n' >&2; exit 2; }
  env_updates="$env_updates,R2_ENDPOINT_URL=$r2_endpoint"
fi
if [[ -n "$r2_bucket" ]]; then
  [[ "$r2_bucket" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$ ]] || { printf 'Invalid R2 bucket.\n' >&2; exit 2; }
  env_updates="$env_updates,R2_BUCKET=$r2_bucket"
fi

command=(
  gcloud run deploy "$service"
  --project "$project_id"
  --region "$region"
  --platform managed
  --image "$image"
  --service-account "$runtime_sa"
  --execution-environment gen2
  --cpu 1
  --memory 512Mi
  --concurrency 80
  --timeout 30
  --min-instances 0
  --max-instances 1
  --cpu-throttling
  --no-cpu-boost
  --no-session-affinity
  --no-traffic
  --tag "$candidate_tag"
  --update-env-vars "$env_updates"
  --quiet
)
if ((${#secret_bindings[@]})); then
  secret_csv="$(IFS=,; printf '%s' "${secret_bindings[*]}")"
  command+=(--update-secrets "$secret_csv")
fi

printf 'Mode: %s\n  ' "$([[ "$apply" == true ]] && printf APPLY || printf DRY-RUN)"
printf '%q ' "${command[@]}"
printf '\n'
printf 'Post-smoke promotion: gcloud run services update-traffic %q --project %q --region %q --to-revisions <candidate-revision>=100 --remove-tags %q\n' \
  "$service" "$project_id" "$region" "$candidate_tag"
if [[ "$public" == true ]]; then
  printf 'Post-promotion IAM (only if needed): gcloud run services add-iam-policy-binding %q --project %q --region %q --member allUsers --role roles/run.invoker\n' \
    "$service" "$project_id" "$region"
else
  printf 'Post-promotion IAM (only if needed): gcloud run services remove-iam-policy-binding %q --project %q --region %q --member allUsers --role roles/run.invoker\n' \
    "$service" "$project_id" "$region"
fi
printf 'Candidate deployment does not change service IAM.\n'

if [[ "$apply" != true ]]; then
  printf 'No resources changed. Re-run with --apply after reviewing the command.\n'
  exit 0
fi

command -v gcloud >/dev/null 2>&1 || { printf 'gcloud is required with --apply.\n' >&2; exit 1; }
python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  printf 'Python 3 is required with --apply.\n' >&2
  exit 1
fi
candidate_tag_active=false
description_file=''
cleanup_on_exit() {
  local status=$?
  trap - EXIT
  if [[ -n "$description_file" ]]; then
    rm -f -- "$description_file"
  fi
  if [[ "$candidate_tag_active" == true ]]; then
    printf 'Release stopped before promotion completed; removing candidate tag %s.\n' \
      "$candidate_tag" >&2
    if gcloud run services update-traffic "$service" \
        --project "$project_id" --region "$region" \
        --remove-tags "$candidate_tag" --quiet; then
      printf 'Removed candidate tag; zero-traffic revision %s and its logs remain available for diagnosis.\n' \
        "${candidate_revision:-unknown}" >&2
    else
      printf 'WARNING: failed to remove candidate tag %s; remove it immediately because its URL may remain reachable.\n' \
        "$candidate_tag" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT

candidate_tag_active=true
"${command[@]}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$repo_root/scripts/check-free-tier.sh" --gcp --project-id "$project_id" --region "$region" --service "$service"

description_file="$(mktemp)"
gcloud run services describe "$service" \
  --project "$project_id" --region "$region" --format=json >"$description_file"

candidate_info="$("$python_bin" - "$description_file" "$candidate_tag" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    service = json.load(handle)
tag = sys.argv[2]
status = service.get("status") or {}
stable_url = str(status.get("url") or "")
matches = [row for row in (status.get("traffic") or []) if row.get("tag") == tag]
if len(matches) != 1:
    print(f"Expected exactly one traffic target tagged {tag!r}; found {len(matches)}", file=sys.stderr)
    raise SystemExit(1)
candidate = matches[0]
candidate_url = str(candidate.get("url") or "")
revision = str(candidate.get("revisionName") or "")
if not stable_url.startswith("https://") or not candidate_url.startswith("https://") or not revision:
    print("Cloud Run did not return a stable URL, tagged URL, and revision name", file=sys.stderr)
    raise SystemExit(1)
print(stable_url)
print(candidate_url)
print(revision)
PY
)"
service_url="$(printf '%s\n' "$candidate_info" | sed -n '1p')"
candidate_url="$(printf '%s\n' "$candidate_info" | sed -n '2p')"
candidate_revision="$(printf '%s\n' "$candidate_info" | sed -n '3p')"

# Candidate deployment deliberately preserves the service's current IAM mode.
# An identity token works whether that mode is currently public or private.
# Cloud Run requires the stable service URL as the token audience even when the
# request itself uses a tagged revision URL.
identity_token="$(gcloud auth print-identity-token --audiences "$service_url")"
smoke_args=(--api-url "$candidate_url" --cloud-run-token "$identity_token")

printf 'Smoke testing zero-traffic candidate revision %s.\n' "$candidate_revision"
if ! "$repo_root/scripts/smoke-test.sh" "${smoke_args[@]}"; then
  printf 'Candidate smoke failed; production traffic was not changed.\n' >&2
  exit 1
fi

promotion=(
  gcloud run services update-traffic "$service"
  --project "$project_id"
  --region "$region"
  --to-revisions "$candidate_revision=100"
  --remove-tags "$candidate_tag"
  --quiet
)
printf 'Candidate smoke passed; promoting the tested revision: '
printf '%q ' "${promotion[@]}"
printf '\n'
"${promotion[@]}"
candidate_tag_active=false

gcloud run services get-iam-policy "$service" \
  --project "$project_id" --region "$region" --format=json >"$description_file"
current_public="$("$python_bin" - "$description_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    policy = json.load(handle)
is_public = any(
    binding.get("role") == "roles/run.invoker"
    and "allUsers" in (binding.get("members") or [])
    for binding in (policy.get("bindings") or [])
)
print("true" if is_public else "false")
PY
)"

if [[ "$public" == true && "$current_public" != true ]]; then
  printf 'Promotion passed; now enabling unauthenticated service invocation.\n'
  gcloud run services add-iam-policy-binding "$service" \
    --project "$project_id" --region "$region" \
    --member allUsers --role roles/run.invoker --quiet
elif [[ "$public" != true && "$current_public" == true ]]; then
  printf 'Promotion passed; now removing unauthenticated service invocation.\n'
  gcloud run services remove-iam-policy-binding "$service" \
    --project "$project_id" --region "$region" \
    --member allUsers --role roles/run.invoker --quiet
else
  printf 'Service IAM already matches the requested %s access mode.\n' \
    "$([[ "$public" == true ]] && printf PUBLIC || printf PRIVATE)"
fi

gcloud run services get-iam-policy "$service" \
  --project "$project_id" --region "$region" --format=json >"$description_file"
"$python_bin" - "$description_file" "$public" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    policy = json.load(handle)
observed_public = any(
    binding.get("role") == "roles/run.invoker"
    and "allUsers" in (binding.get("members") or [])
    for binding in (policy.get("bindings") or [])
)
expected_public = sys.argv[2] == "true"
if observed_public != expected_public:
    print("Service IAM verification failed after promotion", file=sys.stderr)
    raise SystemExit(1)
PY

gcloud run services describe "$service" \
  --project "$project_id" --region "$region" --format=json >"$description_file"
"$python_bin" - "$description_file" "$candidate_revision" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    service = json.load(handle)
expected = sys.argv[2]
active = [
    row
    for row in ((service.get("status") or {}).get("traffic") or [])
    if int(row.get("percent") or 0) > 0
]
if len(active) != 1 or active[0].get("revisionName") != expected or int(active[0].get("percent") or 0) != 100:
    print("Promotion verification failed: tested revision does not have exactly 100% traffic", file=sys.stderr)
    raise SystemExit(1)
PY

printf 'Promoted tested revision %s to 100%% traffic. Cloud Run service URL: %s\n' \
  "$candidate_revision" "$service_url"
if [[ "$public" == true ]]; then
  "$repo_root/scripts/smoke-test.sh" --api-url "$service_url"
else
  "$repo_root/scripts/smoke-test.sh" --api-url "$service_url" \
    --cloud-run-token "$identity_token"
fi
printf 'Final %s access-mode smoke passed.\n' \
  "$([[ "$public" == true ]] && printf PUBLIC || printf PRIVATE)"
printf 'Application writes are %s.\n' "$([[ "$enable_writes" == true ]] && printf ENABLED || printf DISABLED)"
