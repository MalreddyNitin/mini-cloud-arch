#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/load-test.sh --api-url URL [options]

Options:
  --path PATH             Read-only path (default: /health). Allowed prefixes:
                          /health, /ready, /api/items.
  --requests N            Total requests, 1-500 (default: 50).
  --concurrency N         Concurrent requests, 1-10 (default: 2).
  --cloud-run-token TOKEN IAM identity token for a private service. Prefer
                          SMOKE_CLOUD_RUN_TOKEN in the environment.
  --production            Required for any non-loopback URL.
  --help                  Show this help.

This is deliberately a small read-only probe, not a stress test. Review provider
usage immediately after a remote run.
EOF
}

api_url="${API_URL:-}"
path=/health
requests=50
concurrency=2
production=false
cloud_run_token="${SMOKE_CLOUD_RUN_TOKEN:-}"

while (($#)); do
  case "$1" in
    --api-url) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; api_url="$2"; shift ;;
    --path) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; path="$2"; shift ;;
    --requests) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; requests="$2"; shift ;;
    --concurrency) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; concurrency="$2"; shift ;;
    --cloud-run-token) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; cloud_run_token="$2"; shift ;;
    --production) production=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$api_url" ]] || { printf '%s\n' '--api-url is required.' >&2; exit 2; }
[[ "$requests" =~ ^[0-9]+$ ]] && ((requests >= 1 && requests <= 500)) || { printf 'requests must be 1-500.\n' >&2; exit 2; }
[[ "$concurrency" =~ ^[0-9]+$ ]] && ((concurrency >= 1 && concurrency <= 10)) || { printf 'concurrency must be 1-10.\n' >&2; exit 2; }
[[ "$path" == /health || "$path" == /ready || "$path" == /api/items* ]] || { printf 'Only bounded read paths are allowed.\n' >&2; exit 2; }
if [[ ! "$api_url" =~ ^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?(/|$) && "$production" != true ]]; then
  printf 'A non-loopback test requires --production acknowledgement.\n' >&2
  exit 2
fi
command -v curl >/dev/null 2>&1 || { printf 'curl is required.\n' >&2; exit 1; }
python_bin=""
if command -v python3 >/dev/null 2>&1; then python_bin=python3;
elif command -v python >/dev/null 2>&1; then python_bin=python;
else printf 'Python is required to summarize results.\n' >&2; exit 1; fi

api_url="${api_url%/}"
target="$api_url$path"
tmp_dir="$(mktemp -d)"
cleanup() { [[ -n "$tmp_dir" && -d "$tmp_dir" ]] && rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

auth=()
[[ -n "$cloud_run_token" ]] && auth=(-H "Authorization: Bearer $cloud_run_token")

printf 'Running %d read requests at concurrency %d.\n' "$requests" "$concurrency"
for ((start = 1; start <= requests; start += concurrency)); do
  pids=()
  for ((offset = 0; offset < concurrency && start + offset <= requests; offset++)); do
    index=$((start + offset))
    curl --silent --show-error --output /dev/null --connect-timeout 10 --max-time 30 \
      "${auth[@]}" --write-out '%{http_code} %{time_total}\n' "$target" \
      >"$tmp_dir/$index.result" 2>"$tmp_dir/$index.error" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
done

"$python_bin" - "$tmp_dir" "$requests" <<'PY'
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
latencies = []
bad = []
for index in range(1, expected + 1):
    result = root / f"{index}.result"
    try:
        status_text, seconds_text = result.read_text(encoding="utf-8").strip().split()
        status = int(status_text)
        seconds = float(seconds_text)
    except Exception:
        error = (root / f"{index}.error").read_text(encoding="utf-8", errors="replace").strip()
        bad.append((index, "curl-error", error[:160]))
        continue
    latencies.append(seconds * 1000)
    if not 200 <= status < 300:
        bad.append((index, status, ""))

def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return float("nan")
    return values[max(0, min(len(values) - 1, int(round((len(values) - 1) * fraction))))]

print(f"completed={len(latencies)} errors={len(bad)}")
if latencies:
    print(
        f"latency_ms min={min(latencies):.1f} mean={statistics.fmean(latencies):.1f} "
        f"p50={percentile(latencies, .50):.1f} p95={percentile(latencies, .95):.1f} "
        f"p99={percentile(latencies, .99):.1f} max={max(latencies):.1f}"
    )
for entry in bad[:10]:
    print(f"error={entry}", file=sys.stderr)
raise SystemExit(1 if bad else 0)
PY

if [[ "$production" == true ]]; then
  printf 'Remote probe complete. Inspect Cloud Run, Neon, and Billing usage now.\n'
fi
