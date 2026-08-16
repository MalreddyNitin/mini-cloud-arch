# Performance and free-tier efficiency

The goal is useful work per billed request, not maximum benchmark throughput.
No production load test or provider usage measurement has been run by this
repository scaffold, so there is no performance result to claim.

## Fixed initial envelope

- One Cloud Run instance maximum, one vCPU, 512 MiB, request-based CPU,
  concurrency 80, timeout 30 seconds, minimum zero.
- Small SQLAlchemy pool (`2 + 0` overflow initially) through Neon's pooled URL,
  with a 5-second connect timeout and 10-second statement timeout.
- Bounded item pagination and 10 MiB upload permission by default.
- Static fingerprinted frontend assets and direct browser/R2 object transfer.
- No synchronous scraper, export, arbitrary query, or CPU parameter endpoint.

Concurrency 80 is a platform ceiling, not proof the Python/database workload can
efficiently serve 80 simultaneous requests. Measure latency, memory, connection
waits, and error rate; lower concurrency if the single process or pool queues too
long. Do not raise maximum instances during initial tuning.

## Efficient request design

- Select only required columns and keep list responses paginated. Add indexes
  for measured frequent filters, not speculative indexes on a tiny table.
- Avoid N+1 queries and repeated connection setup. Keep transactions short so a
  two-connection pool can serve bursty traffic.
- Cache immutable assets for a year by fingerprint; revalidate the HTML shell.
  Cache stable public JSON only with explicit freshness/invalidation semantics.
- Compress text responses only when payload size makes the CPU tradeoff useful.
- Batch bounded work; reject large exports/scrapes rather than holding a Cloud
  Run request until timeout.
- The API handles only presign JSON. Large bytes travel directly between client
  and R2, avoiding Cloud Run CPU, memory, timeout, and Google outbound transfer.

## Bounded test method

Start locally. Warm once, then use the repository load script with conservative
defaults. It permits only read endpoints and caps both request count and
concurrency:

```bash
scripts/load-test.sh --api-url http://localhost:8080
scripts/load-test.sh --api-url http://localhost:8080 \
  --path '/api/items?limit=20&offset=0' --requests 200 --concurrency 5
```

### Recorded local baseline

On 2026-08-15, the Compose/PostgreSQL stack completed a bounded local run of
`GET /api/items?limit=20&offset=0` with 50 requests and concurrency 2:

| Completed | Errors | Min | Mean | p50 | p95 | p99 / max |
|---:|---:|---:|---:|---:|---:|---:|
| 50 | 0 | 9.4 ms | 15.9 ms | 13.6 ms | 24.6 ms | 56.5 ms |

This is a loopback development baseline, not a Cloud Run result. It measured no
provider usage, cold starts, Internet latency, Neon behavior, or billable cost.

For production, first record baseline provider usage and pass `--production`
explicitly. Stop immediately on errors, latency regression, or a cost warning.
Do not exercise mutations or large objects in a load loop.

After each remote test, record:

- request count, p50/p95/p99 and errors;
- Cloud Run billable instance time, CPU, memory, instance/concurrency, outbound;
- Neon CU-hours, active connections, storage, and query behavior;
- R2 operations/storage if object tests were separate;
- actual/forecast Google cost and Artifact Registry/logging usage.

Then update the measured-usage table in `cost-guardrails.md`. A passing response
test without dashboard measurements does not satisfy the cost acceptance gate.

## Optimization order

1. Fix incorrect/unbounded behavior and query count.
2. Reduce payload/round trips and add appropriate caching.
3. Tune Cloud Run concurrency and the small database pool from measurements.
4. Profile CPU/memory only when metrics show pressure.
5. Graduate intentionally to paid capacity when traffic exceeds the envelope;
   do not hide overload or weaken safety controls to preserve a nominal $0 bill.
