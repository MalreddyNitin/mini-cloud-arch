---
last_verified: 2026-08-15
verification_scope: official provider pricing and limit pages
deployment_status: not provisioned
last_measured_usage: not measured
---

# Cost guardrails

This stack targets a $0 monthly bill; it does not promise one. Free allowances
can change, usage can cross them, and both Google Cloud and R2 require billing
or subscription setup. Re-run the source review and live usage checks before
provisioning and at least monthly thereafter.

## Verified operating envelope

| Service | Official Free allowance used by this design | Local warning threshold | Design control |
|---|---:|---:|---|
| Cloudflare Pages | 500 builds/month; 20,000 files/site; 25 MiB maximum asset | 400 builds | Static Vite output; no Functions |
| Workers / Pages Functions | 100,000 requests/day and 10 ms CPU/invocation on Free | 80,000/day | Not used by the base stack |
| R2 Standard | 10 GB-month storage, 1M Class A and 10M Class B operations/month; direct R2 Internet egress free | 8 GB, 800k A, 8M B | Private Standard bucket; browser-direct transfer |
| Cloud Run, request-based | 2M requests, 180,000 vCPU-seconds, 360,000 GB-seconds memory/month; 1 GB outbound data transfer from North America | 70% review, 85% stop/load-shed | `min=0`, `max=1`, 1 CPU, 512 MiB, 30 s, CPU throttled |
| Artifact Registry | 0.5 GB storage/month | 400 MiB | Retain three recent images; delete versions older than 14 days |
| Secret Manager | 6 active versions and 10,000 access operations/month | 5 active versions, 8,000 accesses | Four pinned production/verification versions initially |
| Neon Free | 100 CU-hours and 0.5 GB storage per project/month; compute up to 2 CU | 80 CU-hours, 0.4 GB | Small pooled connections; relational data only |

Google's Free Program page labels Cloud Run memory usage in GB-seconds, while
the Cloud Run pricing page explains its pricing tables in GiB-seconds. Usage is
applied as a spending-based discount at Tier 1 prices and aggregated across
projects under a billing account. `us-central1` is the chosen primary region.

R2's free allowance applies only to **Standard**, not Infrequent Access. R2
rounds billable usage to billing units, so a small overage can still create a
charge. An R2 subscription/checkout flow is required even though included usage
can make the bill $0.

The local checker treats these Cloudflare list operations as Class A, not Class
B: `ListObjects`, `ListObjectsV2`, `ListMultipartUploads`, and `ListParts`. It
uses decimal provider units (10 GB = 10,000,000,000 bytes). Unknown
analytics action names are reported separately and require manual classification
against the current pricing table.

R2 allowances are account-wide, so the live query intentionally removes any
bucket filter, sums operations across every returned bucket, and prints a bucket
breakdown. Its storage guardrail sums each bucket's observed monthly peak; this
is conservative when peaks occur at different times but avoids undercounting
sparse/misaligned samples. Reaching the 10,000-row analytics limit fails the
check because the response may be truncated. The provider dashboard remains the
authority for billed GB-month.

## Official sources

All links below were read on `2026-08-15`; provider pages showed updates in
2026 where the provider exposed an update date.

| Claim | Primary source |
|---|---|
| Pages builds/files/asset limits and Functions accounting | [Cloudflare Pages limits](https://developers.cloudflare.com/pages/platform/limits/) |
| Workers Free requests and CPU; Pages Functions are Workers usage | [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) and [limits](https://developers.cloudflare.com/workers/platform/limits/) |
| R2 Standard free storage/operations and free egress | [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/) |
| R2 requires an active subscription/checkout | [Cloudflare R2 get started](https://developers.cloudflare.com/r2/get-started/) |
| R2 managed/custom domains can independently expose a bucket | [Cloudflare public buckets](https://developers.cloudflare.com/r2/buckets/public-buckets/) and [domain API](https://developers.cloudflare.com/api/typescript/resources/r2/subresources/buckets/subresources/domains) |
| Cloud Run request-based Free Tier and outbound allowance | [Google Cloud Free Program](https://docs.cloud.google.com/free/docs/free-cloud-features) |
| Cloud Run billing modes, aggregation, region pricing | [Cloud Run pricing](https://cloud.google.com/run/pricing) and [billing settings](https://docs.cloud.google.com/run/docs/configuring/billing-settings) |
| Artifact Registry 0.5 GB allowance | [Google Cloud Free Program](https://docs.cloud.google.com/free/docs/free-cloud-features) |
| Secret Manager versions/operations | [Secret Manager pricing](https://cloud.google.com/secret-manager/pricing) |
| Neon Free CU-hours/storage | [Neon pricing](https://neon.com/pricing) |
| Google alert-budget behavior | [Cloud Billing budgets](https://docs.cloud.google.com/billing/docs/how-to/budgets) |

## Controls that actually constrain usage

- `infra/gcp/deploy-cloud-run.sh` hard-codes request-oriented settings: minimum
  zero, maximum one, one CPU, 512 MiB, concurrency 80, timeout 30 seconds, CPU
  throttling, no startup CPU boost, and no session affinity.
- Production application writes and both presign endpoints default to disabled.
  Enabling them requires an explicit setting; production additionally requires
  a server-side key of at least 32 characters. A key must never enter browser
  code, so user-facing writes need real identity/authorization before launch.
- Uploads are capped at 10 MiB by default, content types are allowlisted, list
  requests are paginated/bounded, and presigned URLs expire after five minutes.
- R2 data flows browser-to-R2. Cloud Run never becomes a large-object relay.
- The bucket stays private and Standard-class. The bootstrap script has no
  public-bucket or Infrequent Access option.
- Artifact cleanup prevents every commit image from accumulating indefinitely.
- Cloud Run and CD reference numeric Secret Manager versions. The initial three
  runtime versions plus one direct-DB verification version fit within the six-
  version allowance; rotations must destroy old versions after rollback windows
  or can become billable.

Run static checks in CI and live checks from an authenticated operator shell:

```bash
scripts/check-free-tier.sh --static
scripts/check-free-tier.sh --gcp --project-id "$GCP_PROJECT_ID"
scripts/check-free-tier.sh --r2
scripts/check-free-tier.sh --neon
```

The R2 check queries account-wide Cloudflare GraphQL analytics and reports both
per-bucket totals and unknown action types for manual classification; analytics
datasets and operation names can evolve. The Neon check measures database bytes,
but CU-hours must still be
checked in the Neon dashboard. Cloud Run compute/request metrics and actual
billing must be reviewed in Google Cloud because configuration alone cannot
prove $0 usage.

## Controls that only alert

The bootstrap script can create a USD 1 Google **alerts-only** monthly budget at
50%, 90%, and 100%. Google explicitly warns that alerts-only budgets do not cap
usage or spending, and cost reporting/notifications can be delayed. Treat the
first alert as an incident, not spare budget. Spend-cap budgets may appear for
eligible services/accounts, but are not assumed by this design.

Cloudflare and Neon dashboards/notifications are likewise monitoring controls,
not proof of a hard stop. Do not upgrade a plan, enable paid Workers, add a
minimum instance, or raise maximum scale without an explicit cost review.

## What can create a bill

- Any Cloud Run request/CPU/memory/outbound usage beyond the billing-account
  allowance; cross-region/VPC connectors/load balancers; a nonzero minimum;
  instance-based billing; excessive logs; or stored Artifact Registry images.
- More than six active Secret Manager versions or more than 10,000 access
  operations per month across the billing account.
- R2 Standard bytes or operations above the allowance, any Infrequent Access
  usage/retrieval, optional metered services connected to R2, or accidental
  paid Cloudflare plan/features.
- Moving the Neon project to a usage-based plan or exceeding a changed plan
  contract. Free-plan service may instead throttle/suspend; verify current UI.
- Domains, auth vendors, monitoring products, support, and other services not
  included in this envelope.

## Monthly review record

Do not replace unknowns with zero. Record provider dashboard values after each
load test and monthly while production is active.

| Period | Cloud Run req / vCPU-s / memory-s / outbound | Artifact bytes | R2 GB-month / A / B | Neon CU-hours / storage | Bill | Reviewer |
|---|---|---|---|---|---|---|
| Not deployed | Not measured | Not measured | Not measured | Not measured | Unknown | — |

## Stop procedure

1. Set application writes off and revoke/rotate the write key and R2 token if
   abuse is suspected.
2. Set Cloud Run ingress private or remove `allUsers` invoker access. Keep
   `min-instances=0` and `max-instances=1`.
3. Pause Cloudflare Pages deployments; disable an optional Worker route if one
   was later added. Do not delete data during triage.
4. Review actual billing/usage and identify the meter before changing quotas.
5. If charges continue, an authorized billing administrator can unlink billing,
   accepting that Google services stop and resources may eventually be lost.
   Budgets alone do not do this.
