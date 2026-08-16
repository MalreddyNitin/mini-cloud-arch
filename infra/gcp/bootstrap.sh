#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: infra/gcp/bootstrap.sh --project-id ID --github-repo OWNER/REPO [options]

Safe default: prints the proposed commands. Nothing is changed without --apply.

Options:
  --project-id ID          Dedicated Google Cloud project ID (required).
  --github-repo OWNER/REPO Exact GitHub repository allowed to federate.
  --github-branch BRANCH   Allowed deploy branch (default: main).
  --region REGION          Default Cloud Run/Artifact Registry region
                           (default: us-central1).
  --repository NAME        Artifact Registry repository (default: zero-cloud).
  --billing-account ID     Link billing and create a USD 1 alerts-only budget.
  --organization ID        Optional organization for new project creation.
  --folder ID              Optional folder for new project creation.
  --apply                   Execute the displayed commands.
  --help                    Show this help.

Creates/updates a GitHub OIDC provider restricted to the exact repository and
branch, plus deploy/runtime service accounts. It never creates a JSON key.
Billing is required for Cloud Run even when usage stays inside Free Tier.
Google alert budgets do not hard-stop spend.
EOF
}

apply=false
project_id="${GCP_PROJECT_ID:-}"
github_repo="${GITHUB_REPOSITORY:-}"
github_branch=main
region="${GCP_REGION:-us-central1}"
repository="${GCP_ARTIFACT_REPOSITORY:-zero-cloud}"
billing_account=""
organization=""
folder=""
pool_id=github
provider_id=github-main
deploy_sa_id=github-deployer
runtime_sa_id=cloud-run-runtime

while (($#)); do
  case "$1" in
    --project-id) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; project_id="$2"; shift ;;
    --github-repo) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; github_repo="$2"; shift ;;
    --github-branch) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; github_branch="$2"; shift ;;
    --region) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; region="$2"; shift ;;
    --repository) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; repository="$2"; shift ;;
    --billing-account) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; billing_account="$2"; shift ;;
    --organization) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; organization="$2"; shift ;;
    --folder) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; folder="$2"; shift ;;
    --apply) apply=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { printf 'A valid --project-id is required.\n' >&2; exit 2; }
[[ "$github_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { printf 'A valid --github-repo OWNER/REPO is required.\n' >&2; exit 2; }
[[ "$github_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { printf 'Invalid --github-branch.\n' >&2; exit 2; }
[[ "$region" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || { printf 'Invalid --region.\n' >&2; exit 2; }
[[ "$repository" =~ ^[a-z][a-z0-9._-]{2,62}$ ]] || { printf 'Invalid --repository.\n' >&2; exit 2; }
if [[ -n "$organization" && -n "$folder" ]]; then
  printf 'Use only one of --organization or --folder.\n' >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cleanup_policy="$repo_root/infra/gcp/artifact-cleanup-policy.json"

print_command() {
  printf '  '
  printf '%q ' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  if [[ "$apply" == true ]]; then
    "$@"
  fi
}

if [[ "$apply" == true ]]; then
  command -v gcloud >/dev/null 2>&1 || { printf 'gcloud is required with --apply.\n' >&2; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || {
    printf 'No active gcloud account. Run gcloud auth login first.\n' >&2
    exit 1
  }
fi

printf 'Mode: %s\n' "$([[ "$apply" == true ]] && printf APPLY || printf DRY-RUN)"
printf 'Project: %s; region: %s; GitHub subject: %s@refs/heads/%s\n' \
  "$project_id" "$region" "$github_repo" "$github_branch"

project_exists=false
if [[ "$apply" == true ]] && gcloud projects describe "$project_id" --format='value(projectId)' >/dev/null 2>&1; then
  project_exists=true
fi
if [[ "$project_exists" == false ]]; then
  create_project=(gcloud projects create "$project_id" --name='Zero Cloud Stack')
  [[ -n "$organization" ]] && create_project+=(--organization "$organization")
  [[ -n "$folder" ]] && create_project+=(--folder "$folder")
  run "${create_project[@]}"
else
  printf '  Project already exists; leaving ownership/lifecycle unchanged.\n'
fi

if [[ -n "$billing_account" ]]; then
  run gcloud billing projects link "$project_id" --billing-account "$billing_account"
else
  printf '  NOTE: no billing account supplied; Cloud Run deployment will remain blocked.\n'
fi

run gcloud services enable \
  run.googleapis.com artifactregistry.googleapis.com iamcredentials.googleapis.com \
  sts.googleapis.com cloudresourcemanager.googleapis.com secretmanager.googleapis.com \
  billingbudgets.googleapis.com \
  --project "$project_id"

for sa_id in "$deploy_sa_id" "$runtime_sa_id"; do
  if [[ "$apply" == true ]] && gcloud iam service-accounts describe \
      "$sa_id@$project_id.iam.gserviceaccount.com" --project "$project_id" >/dev/null 2>&1; then
    printf '  Service account %s already exists.\n' "$sa_id"
  else
    display='Cloud Run runtime'
    [[ "$sa_id" == "$deploy_sa_id" ]] && display='GitHub Actions deployer'
    run gcloud iam service-accounts create "$sa_id" --display-name "$display" --project "$project_id"
  fi
done

deploy_sa="$deploy_sa_id@$project_id.iam.gserviceaccount.com"
runtime_sa="$runtime_sa_id@$project_id.iam.gserviceaccount.com"

run gcloud projects add-iam-policy-binding "$project_id" \
  --member "serviceAccount:$deploy_sa" --role roles/run.admin --condition=None
run gcloud iam service-accounts add-iam-policy-binding "$runtime_sa" \
  --member "serviceAccount:$deploy_sa" --role roles/iam.serviceAccountUser --project "$project_id"

if [[ "$apply" == true ]] && gcloud artifacts repositories describe "$repository" \
    --location "$region" --project "$project_id" >/dev/null 2>&1; then
  printf '  Artifact Registry repository already exists.\n'
else
  run gcloud artifacts repositories create "$repository" --repository-format docker \
    --location "$region" --description 'Zero Cloud API images' --project "$project_id"
fi
run gcloud artifacts repositories add-iam-policy-binding "$repository" \
  --location "$region" --project "$project_id" \
  --member "serviceAccount:$deploy_sa" --role roles/artifactregistry.writer
run gcloud artifacts repositories set-cleanup-policies "$repository" \
  --location "$region" --project "$project_id" --policy "$cleanup_policy"

if [[ "$apply" == true ]] && gcloud iam workload-identity-pools describe "$pool_id" \
    --location global --project "$project_id" >/dev/null 2>&1; then
  printf '  Workload Identity Pool already exists.\n'
else
  run gcloud iam workload-identity-pools create "$pool_id" --location global \
    --display-name 'GitHub Actions' --project "$project_id"
fi

attribute_mapping='google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.actor=assertion.actor'
attribute_condition="assertion.repository == '$github_repo' && assertion.ref == 'refs/heads/$github_branch'"
if [[ "$apply" == true ]] && gcloud iam workload-identity-pools providers describe "$provider_id" \
    --workload-identity-pool "$pool_id" --location global --project "$project_id" >/dev/null 2>&1; then
  run gcloud iam workload-identity-pools providers update-oidc "$provider_id" \
    --workload-identity-pool "$pool_id" --location global --project "$project_id" \
    --attribute-mapping "$attribute_mapping" --attribute-condition "$attribute_condition" \
    --issuer-uri https://token.actions.githubusercontent.com
else
  run gcloud iam workload-identity-pools providers create-oidc "$provider_id" \
    --workload-identity-pool "$pool_id" --location global --project "$project_id" \
    --display-name 'GitHub main branch' --attribute-mapping "$attribute_mapping" \
    --attribute-condition "$attribute_condition" \
    --issuer-uri https://token.actions.githubusercontent.com
fi

if [[ "$apply" == true ]]; then
  project_number="$(gcloud projects describe "$project_id" --format='value(projectNumber)')"
else
  project_number='<PROJECT_NUMBER>'
fi
pool_resource="projects/$project_number/locations/global/workloadIdentityPools/$pool_id"
provider_resource="$pool_resource/providers/$provider_id"
run gcloud iam service-accounts add-iam-policy-binding "$deploy_sa" \
  --project "$project_id" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/$pool_resource/attribute.repository/$github_repo"

if [[ -n "$billing_account" ]]; then
  budget_name='zero-cloud-alerts-only-usd-1'
  existing_budget=''
  if [[ "$apply" == true ]]; then
    existing_budget="$(gcloud billing budgets list --billing-account "$billing_account" \
      --filter "displayName=$budget_name" --format='value(name)' --limit=1 || true)"
  fi
  if [[ -n "$existing_budget" ]]; then
    printf '  Budget %s already exists.\n' "$budget_name"
  else
    run gcloud billing budgets create --billing-account "$billing_account" \
      --display-name "$budget_name" --budget-amount 1USD --calendar-period month \
      --filter-projects "projects/$project_number" \
      --threshold-rule percent=0.50 --threshold-rule percent=0.90 \
      --threshold-rule percent=1.00
  fi
  printf '  CAUTION: this is an alerts-only budget; it does not cap or stop spend.\n'
fi

cat <<EOF

Set these GitHub Actions repository variables after verifying the resources:
  GCP_PROJECT_ID=$project_id
  GCP_REGION=$region
  GCP_ARTIFACT_REPOSITORY=$repository
  CLOUD_RUN_SERVICE_NAME=zero-cloud-api
  GCP_WORKLOAD_IDENTITY_PROVIDER=$provider_resource
  GCP_DEPLOY_SERVICE_ACCOUNT=$deploy_sa
  CLOUD_RUN_RUNTIME_SERVICE_ACCOUNT=$runtime_sa
  CLOUD_RUN_PUBLIC_API=false
  APP_ORIGIN=https://<your-pages-project>.pages.dev
  R2_ENDPOINT_URL=https://<cloudflare-account-id>.r2.cloudflarestorage.com
  R2_BUCKET=zero-cloud-prod
  DATABASE_URL_SECRET=zero-cloud-database-url:1
  DATABASE_URL_DIRECT_SECRET=zero-cloud-database-url-direct:1
  R2_ACCESS_KEY_ID_SECRET=zero-cloud-r2-access-key-id:1
  R2_SECRET_ACCESS_KEY_SECRET=zero-cloud-r2-secret-access-key:1

No service-account key was created. Review every IAM binding and the billing
dashboard before enabling deployment. After creating secrets, grant $deploy_sa
access only to the pinned direct-DB verification secret; grant $runtime_sa only
the pooled DB and R2 runtime secrets. See docs/deployment.md.
EOF
