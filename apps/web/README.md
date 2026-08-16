# Zero Cloud web

Static React + TypeScript SPA for Cloudflare Pages. It talks to the API with small JSON requests and uploads file bytes directly to R2 using short-lived presigned URLs.

## Local development

```bash
npm ci
npm run dev
```

The development default is `http://localhost:8080`. Override it without putting credentials in the frontend:

```dotenv
VITE_API_BASE_URL=https://your-api.example.com
```

`VITE_API_BASE_URL` is public build-time configuration, not a place for a token or secret. A production build or preview fails when it is missing, relative, non-HTTPS, or contains credentials/query parameters. This prevents Cloudflare Pages' SPA fallback from being mistaken for an API response. Production writes may be disabled by the API; the UI surfaces that state without asking for or storing credentials.

Upload validation mirrors the API allowlist: JPEG, PNG, WebP, PDF, plain text, CSV, JSON, and ZIP, with a 10 MiB maximum. The API remains authoritative.

## Quality checks

```bash
npm run lint
npm run typecheck
npm test
npm run build
```

For a local production-build check, provide a non-secret HTTPS API origin in the shell environment before running `npm run build`.

Cloudflare Pages settings:

- Root directory: `apps/web`
- Build command: `npm ci && npm run build`
- Output directory: `dist`
- Environment variable: `VITE_API_BASE_URL`

`public/_redirects` supplies the SPA history fallback, while `public/_headers` supplies security and immutable-asset cache headers.
