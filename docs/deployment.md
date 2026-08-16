# Deployment

This runbook prepares and deploys the stack without long-lived Google keys.
Every provider step changes external state and must be run by an authorized
operator. As committed, the repository has **not** created accounts, attached
billing, enabled subscriptions, set MFA, or deployed resources.

## 1. Prerequisites and account gate

- GitHub repository with MFA, secret scanning, push protection, protected
  `main`, required `CI` checks, and a protected `production` environment.
- Dedicated Google Cloud project, billing administrator, `gcloud`, Docker, and
  a confirmed low-risk region. This stack defaults to `us-central1`.
- Cloudflare account with MFA and an active R2 subscription. R2 checkout is
  required even though included usage can result in $0.
- Neon Free account with MFA and `psql`/PostgreSQL client tools.
- Review [`cost-guardrails.md`](cost-guardrails.md) on the day of provisioning.

Do not proceed if the current provider contract introduces unavoidable
recurring cost or if the operator cannot receive billing alerts.

## 2. Local release gate

```bash
cp .env.example .env
make test
make dev-detached
scripts/smoke-test.sh --api-url http://localhost:8080
docker compose down
```

The ordinary test path uses local/disposable data and no cloud credentials.
Local Compose enables unauthenticated writes only on loopback for development.

## 3. Neon

Follow [`infra/neon/migrations.md`](../infra/neon/migrations.md). Capture the
pooled production URL for Cloud Run. Keep the privileged direct URL only in the
operator environment for migrations/backups. Create a separate direct-endpoint
URL whose database role can only connect and select `alembic_version`; store
that verifier URL in one pinned Secret Manager version for CD. All URLs must
require TLS.

## 4. R2

First review, then apply private Standard-bucket creation:

```bash
export CF_ACCOUNT_ID='<account-id>'
export CLOUDFLARE_API_TOKEN='<operator-token>'

infra/cloudflare/r2-bootstrap.sh \
  --account-id "$CF_ACCOUNT_ID" \
  --bucket zero-cloud-prod \
  --location wnam

# Only after reviewing the output:
infra/cloudflare/r2-bootstrap.sh \
  --account-id "$CF_ACCOUNT_ID" \
  --bucket zero-cloud-prod \
  --location wnam \
  --apply
```

Create a separate R2 S3 token scoped to this bucket and only the operations the
API needs. Record the S3 endpoint, access key ID, and secret exactly once in a
secure operator session. Do not make the bucket public. Configure exact-origin
CORS after the Pages hostname is known, as described in
[`pages-notes.md`](../infra/cloudflare/pages-notes.md).
The bootstrap checks both the managed `r2.dev` development URL and enabled
custom domains when the Cloudflare API permits it. Treat any check warning as a
manual dashboard gate; private S3 authorization does not disable a public route.

## 5. Google project, registry, WIF, and budget

The bootstrap defaults to dry-run. It creates no Google key and constrains the
OIDC provider to the exact repository and `main` branch.

```bash
infra/gcp/bootstrap.sh \
  --project-id '<dedicated-project-id>' \
  --github-repo '<owner>/<repository>' \
  --billing-account '<billing-account-id>'

# Review project creation, billing link, IAM, registry cleanup, WIF, and budget.
# Then explicitly apply:
infra/gcp/bootstrap.sh \
  --project-id '<dedicated-project-id>' \
  --github-repo '<owner>/<repository>' \
  --billing-account '<billing-account-id>' \
  --apply
```

Inspect all emitted IAM policies. The deploy account has Cloud Run Admin (needed
to change public invoker policy), writer access only to the selected Artifact
Registry repository, and Service Account User only on the runtime identity. A
later per-secret binding lets it read only the direct Neon verification URL. The
runtime identity receives no project-wide role by default and must not receive
the direct migration URL.

The USD 1 budget is alerts-only. Confirm its recipients and remember it neither
caps nor instantly reports spend.

## 6. Store runtime and verification secrets in Google Secret Manager

Create four secrets and add one version to each. Grant the runtime identity
access only to the pooled database URL and R2 credentials. Grant the deploy
identity access only to the direct database URL used for the read-only migration
check. Never grant either identity project-wide Secret Manager access. Use a
hidden prompt or secure file input so values do not enter shell history.

```bash
gcloud secrets create zero-cloud-database-url --replication-policy=automatic --project "$GCP_PROJECT_ID"
gcloud secrets create zero-cloud-database-url-direct --replication-policy=automatic --project "$GCP_PROJECT_ID"
gcloud secrets create zero-cloud-r2-access-key-id --replication-policy=automatic --project "$GCP_PROJECT_ID"
gcloud secrets create zero-cloud-r2-secret-access-key --replication-policy=automatic --project "$GCP_PROJECT_ID"

# Example for one value; repeat with the correct secret and secret value.
read -r -s -p 'Secret value: ' ZERO_CLOUD_SECRET_VALUE
printf '%s' "$ZERO_CLOUD_SECRET_VALUE" | gcloud secrets versions add \
  zero-cloud-database-url --data-file=- --project "$GCP_PROJECT_ID"
unset ZERO_CLOUD_SECRET_VALUE

runtime_sa="cloud-run-runtime@$GCP_PROJECT_ID.iam.gserviceaccount.com"
deploy_sa="github-deployer@$GCP_PROJECT_ID.iam.gserviceaccount.com"
for secret_name in zero-cloud-database-url zero-cloud-r2-access-key-id zero-cloud-r2-secret-access-key; do
  gcloud secrets add-iam-policy-binding "$secret_name" \
    --project "$GCP_PROJECT_ID" \
    --member "serviceAccount:$runtime_sa" \
    --role roles/secretmanager.secretAccessor
done

gcloud secrets add-iam-policy-binding zero-cloud-database-url-direct \
  --project "$GCP_PROJECT_ID" \
  --member "serviceAccount:$deploy_sa" \
  --role roles/secretmanager.secretAccessor
```

Use the pooled Neon URL in `zero-cloud-database-url`. Put the TLS-required URL
for the dedicated, read-only schema-verifier role in
`zero-cloud-database-url-direct`; do not store the migration-owner URL there.
The deploy workflow retrieves that one verifier value transiently, masks it
before use, runs a single `SELECT` through `psql`, and unsets it; it never
applies a migration. Record numeric versions
with `gcloud secrets versions list`; workflows and revisions intentionally do
not bind `latest`. Four active versions fit the currently verified six-version
free allowance. During rotation, keep only a deliberate rollback window and
destroy obsolete versions after validation.

## 7. GitHub configuration

Set the repository/environment variables printed by `bootstrap.sh`:

| Variable | Example/meaning |
|---|---|
| `ENABLE_PRODUCTION_DEPLOY` | Keep unset/`false` until every provider resource, protected variable, pinned secret version, migration, and environment review is complete; then set exactly `true` |
| `GCP_PROJECT_ID` | Dedicated project ID |
| `GCP_REGION` | `us-central1` |
| `GCP_ARTIFACT_REPOSITORY` | `zero-cloud` |
| `CLOUD_RUN_SERVICE_NAME` | `zero-cloud-api` |
| `CLOUD_RUN_RUNTIME_SERVICE_ACCOUNT` | Runtime service-account email |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full provider resource name |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | Deployer service-account email |
| `APP_ORIGIN` | Exact future/current Pages HTTPS origin |
| `R2_ENDPOINT_URL` | `https://<account>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | Private bucket name |
| `DATABASE_URL_SECRET` | `zero-cloud-database-url:1` |
| `DATABASE_URL_DIRECT_SECRET` | `zero-cloud-database-url-direct:1`; deploy-only read gate |
| `R2_ACCESS_KEY_ID_SECRET` | `zero-cloud-r2-access-key-id:1` |
| `R2_SECRET_ACCESS_KEY_SECRET` | `zero-cloud-r2-secret-access-key:1` |
| `PRODUCTION_MIGRATION_REVISION` | Exact Alembic revision already applied to production |
| `CLOUD_RUN_PUBLIC_API` | Start `false`; use `true` for public read-only Pages access |

These are identifiers/configuration, not secret values. Configure required
reviewers on the GitHub `production` environment. Restrict who can change its
variables, especially `PRODUCTION_MIGRATION_REVISION`. Require CI on `main`
before merge. Leave `ENABLE_PRODUCTION_DEPLOY` unset while bootstrapping: this
makes early CI runs skip the production job instead of failing against missing
infrastructure. Set it to exactly `true` only after completing Sections 1–7 and
the production-environment review. The deploy workflow then runs only after a
successful `push` CI run on this repository's default branch (not a fork or PR)
and checks out the exact trusted/tested SHA. It has no manual-dispatch path that
can bypass CI lineage.

## 8. Migrate, deploy, and verify

Apply a reviewed backward-compatible migration once from the operator shell and
confirm `alembic current` equals the repository's sole `alembic heads` revision.
Only after that succeeds, set the protected GitHub environment variable
`PRODUCTION_MIGRATION_REVISION` to that exact revision. Never update the marker
before the database. The deploy workflow compares the marker with the checked-
out migration graph and fails closed on a mismatch or multiple heads. After WIF
authentication it retrieves the pinned direct-URL secret and performs a read-
only query of production `alembic_version`. A missing `psql`, inaccessible
secret/database, multiple rows, or revision mismatch blocks release before the
image is pushed. Production migrations remain a separate serialized operator
action; CD never runs `alembic upgrade`.

Then merge to `main`; the successful `push` CI run triggers **Deploy API**. The
workflow builds a commit-SHA image, scans that exact candidate, pushes it,
resolves its registry digest, and deploys only that digest. It creates a
uniquely tagged Cloud Run revision with fixed cost settings and **zero traffic**.
It checks the configuration and runs the read-only health, readiness, and
bounded item-list smoke tests against that tagged revision using Cloud Run IAM. Candidate deploy
does not add or remove the service-wide `allUsers` invoker binding, so switching
between public and private cannot expose or take down the old revision before
the candidate passes. Only a passing candidate is promoted to 100% traffic;
then CD reconciles the requested public/private IAM mode, verifies the exact
binding, and smoke tests the stable URL in that final mode. A failed candidate
remains at zero traffic, its tag is removed on a best-effort basis, and no
previous production traffic or IAM allocation is changed. The untagged revision
and its logs remain available for diagnosis.

If the workflow warns that tag cleanup failed, remove the routable tag
immediately while retaining the revision:

```bash
gcloud run services update-traffic "$CLOUD_RUN_SERVICE_NAME" \
  --project "$GCP_PROJECT_ID" --region "$GCP_REGION" \
  --remove-tags 'candidate-<sha-prefix>'
```

For a public Pages client, change `CLOUD_RUN_PUBLIC_API=true` only after
confirming production `ENABLE_WRITES=false`. This exposes health/read endpoints;
write and presign endpoints remain denied at the application layer.

Verify independently:

```bash
scripts/check-free-tier.sh --gcp
gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" \
  --project "$GCP_PROJECT_ID" --region "$GCP_REGION"
```

Wait for idle and confirm active instances return to zero in Cloud Run metrics.
Inspect Billing, Artifact Registry bytes, and logs.

## 9. Pages

Apply [`infra/cloudflare/pages-notes.md`](../infra/cloudflare/pages-notes.md),
then update the exact API CORS origin and R2 CORS rule. Do not add the operator
write key to Vite/Pages. Set Pages `VITE_API_BASE_URL` to the real deployed HTTPS
Cloud Run URL; CI's `https://api.example.invalid` value is only a credential-free
build validator. Run:

```bash
scripts/smoke-test.sh --api-url 'https://<run-url>' \
  --web-url 'https://<pages-url>'
```

For an authorized full R2 test, explicitly enable protected writes, supply the
write key only to the operator script, and provide bucket-scoped S3 credentials
so cleanup is guaranteed. The full test sends a 10 MiB object by default. To test
a larger object, set the deployed API and operator shell `MAX_UPLOAD_BYTES` to
the same reviewed value (never above 100 MiB), then pass `--r2-size-bytes`; the
script rejects a payload above that cap. Immediately disable writes again if the
product is still public read-only.
