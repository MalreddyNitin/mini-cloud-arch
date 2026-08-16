# Security

## Baseline posture

The base production application is public read-only. All item mutations and R2
presign endpoints default to disabled. When an operator enables writes,
production requires a random server-side key of at least 32 characters, but
that shared key is only suitable for operator smoke tests—not browser users.
There is no safe way to embed it in Vite/Pages assets.

Before user-facing writes, add standards-based authentication, validate tokens
server-side, authorize each resource/tenant, implement revocation/session policy,
and add abuse controls. Do not turn on public writes to make a demo pass.

## Trust and secret controls

- GitHub deploys through short-lived OIDC/WIF. The provider condition restricts
  admission to the exact repository and `refs/heads/main`; no Google JSON key
  is created or accepted by workflows.
- GitHub's `production` environment should require reviewers. Workflow token
  permissions are only `contents: read` and `id-token: write`.
- Cloud Run binds numeric Secret Manager versions. The runtime identity receives
  per-secret accessor bindings for only pooled DB/R2 values; it has no
  deployment/project admin role and cannot read the direct migration URL. The
  deploy identity can read only a direct URL for a dedicated database role
  restricted to selecting `alembic_version`; the value is masked and used only
  for the pre-release schema check.
- R2 uses a bucket-scoped S3 token. Secret keys never reach the browser; browsers
  receive operation/key/expiry-specific URLs for at most five minutes.
- Pages variables are public build inputs. Only `VITE_API_BASE_URL` belongs
  there. Never add credentials, shared keys, or private endpoints.
- `.gitignore`, CI policy checks, Dependabot, GitHub secret scanning, and push
  protection form layers; none substitutes for rotation after exposure.

## Application controls

- Strict origin allowlist; no wildcard CORS with credentials.
- Request models reject malformed/unexpected data. ORM queries remain
  parameterized. Pagination and upload size/type are bounded.
- Object keys are generated server-side and do not trust a client filename as a
  path. The private bucket and exact-origin CORS remain separate from auth.
- Security headers are set by the API/frontend. HTTPS is enforced by managed
  origins. Responses do not include stack traces or connection details.
- Structured logs omit bodies, authorization headers, database/R2 credentials,
  and complete presigned URLs. Request IDs allow correlation without secrets.
- Cloud Run has no durable local state; process restarts cannot lose required
  data or preserve unauthorized uploads.

## Primary threats and responses

| Threat | Prevent/detect | Response |
|---|---|---|
| Public mutation/denial-of-wallet | Writes off, key for operator tests, max scale one, bounded inputs | Disable public invoker/writes; rotate token; inspect usage |
| Presigned URL leakage | Short TTL, one object/operation, private bucket, no URL logging | Wait/revoke underlying token if material; delete unauthorized object |
| CI cloud takeover | Trusted-repo push event check, repo/ref-conditioned WIF, protected environment, least privilege | Disable provider/deployer, audit logs, rotate direct DB credential |
| Database credential theft | Secret Manager, TLS, pooled runtime role | Rotate Neon role/secret version; revoke old role; inspect data |
| Supply-chain vulnerability | Locks, Dependabot, lint/tests, pinned Trivy action/CLI, image scan | Patch lock/base image, rebuild/test SHA, redeploy |
| XSS/static compromise | React escaping, CSP/security headers, no browser secrets | Revert Pages deployment, rotate any exposed external tokens |

The vulnerability scanner wrapper is pinned to a full reviewed commit and its
Trivy CLI version is explicit because mutable third-party action tags are a
supply-chain risk. Dependabot should propose reviewed updates.

## Account/provider checklist (manual, not verified by code)

- MFA enabled and recovery methods tested for GitHub, Google, Cloudflare, Neon.
- Minimal administrators; inactive users/apps/tokens removed.
- GitHub secret scanning and push protection enabled where the repository plan
  permits; branch protection requires all CI jobs and review.
- Google billing recipients and audit logs reviewed; WIF/IAM bindings match docs.
- Cloudflare R2 subscription and token scope checked; both the `r2.dev`
  development URL and every custom-domain public route are off.
- Neon role privileges, TLS, branch inventory, storage, and CU usage checked.
- Incident owner and credential-rotation procedure recorded outside the repo.

## Rotation

Create new provider credentials/secret versions, grant/test them on a private
revision, promote, revoke old provider credentials, then destroy obsolete
Secret Manager versions after the rollback window. Keep active versions within
the verified free allowance. A Git deletion is not revocation.

## Security acceptance test

- Production starts with `ENABLE_WRITES=false`; mutation/presign calls are
  denied without leaking whether an object exists.
- When writes are explicitly enabled, missing/wrong bearer keys fail and a valid
  operator key succeeds; headers never appear in logs.
- Oversized/type-disallowed uploads and excessive pagination are rejected.
- `/health` survives a database outage; `/ready` fails cleanly.
- Direct R2 PUT/GET succeeds only for the signed operation/content type and the
  exact smoke object is removed afterward.
- CI, image scan, WIF config check, and live guardrail check pass.
