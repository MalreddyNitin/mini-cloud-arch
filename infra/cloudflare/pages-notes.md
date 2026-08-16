# Cloudflare Pages configuration

Status: **not provisioned by this repository**. These are the exact dashboard
settings to apply after CI is green and the Cloud Run origin is known.

Prefer the native Cloudflare Git integration. It provides production and pull
request preview deployments without storing a Cloudflare API token in GitHub.
Cloudflare documents that a Git-integrated Pages project cannot later be
converted to Direct Upload, so make that choice deliberately.

## Build settings

| Setting | Value |
|---|---|
| Production branch | `main` |
| Root directory | `apps/web` |
| Build command | `npm ci && npm run build` |
| Build output directory | `dist` |
| Node version | `24` (set `NODE_VERSION=24`) |
| Production variable | `VITE_API_BASE_URL=https://<cloud-run-service-url>` |

Do not put `WRITE_API_KEY`, R2 credentials, database URLs, or any other secret
in Pages variables. Vite variables are compiled into public browser assets.
The `https://api.example.invalid` value used by CI is only a build validator;
never copy it into the Pages production environment.

The frontend includes `public/_redirects` for SPA refresh fallback. Vite emits
fingerprinted assets, which can use long cache lifetimes; `index.html` should be
revalidated so new asset manifests propagate. No Pages Function is needed for
the base stack. Adding one would consume the Workers Free request allowance.

## Dashboard procedure

1. In **Workers & Pages**, choose **Create application > Pages > Connect to
   Git** and grant access only to this repository.
2. Apply the settings above and set the production environment variable.
3. Keep preview deployments enabled only if their build volume remains useful;
   the Free plan has a 500-build monthly limit.
4. Deploy and check the Pages status in GitHub.
5. Set the exact Pages origin as the API's `APP_ORIGIN` and `CORS_ORIGINS`, then
   redeploy Cloud Run.
6. Configure R2 CORS for the same exact origin:

   ```bash
   infra/cloudflare/r2-bootstrap.sh \
     --account-id "$CF_ACCOUNT_ID" \
     --bucket "$R2_BUCKET" \
     --cors-origin "https://<project>.pages.dev"
   ```

   Review the dry run, then repeat with `--apply`.

7. Run `scripts/smoke-test.sh --api-url ... --web-url ...`. A full mutation/R2
   smoke test is an operator action and requires protected write access plus
   bucket-scoped cleanup credentials.

Official references, verified 2026-08-15:

- [Pages Git integration](https://developers.cloudflare.com/pages/configuration/git-integration/)
- [Pages build configuration](https://developers.cloudflare.com/pages/configuration/build-configuration/)
- [Pages limits](https://developers.cloudflare.com/pages/platform/limits/)
- [R2 browser CORS](https://developers.cloudflare.com/r2/buckets/cors/)
- [R2 public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- [R2 domain API](https://developers.cloudflare.com/api/typescript/resources/r2/subresources/buckets/subresources/domains)
