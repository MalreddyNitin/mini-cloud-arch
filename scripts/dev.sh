#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/dev.sh [--detach] [--no-build] [--help]

Starts the local PostgreSQL + API stack. Cloud credentials are not required.
The database volume is preserved when the stack is stopped.
EOF
}

detach=false
build=true
while (($#)); do
  case "$1" in
    --detach) detach=true ;;
    --no-build) build=false ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required. Install Docker Desktop or Docker Engine with Compose v2.\n' >&2
  exit 1
}

docker compose version >/dev/null
docker compose config --quiet

args=(up --remove-orphans)
if [[ "$build" == true ]]; then
  args+=(--build)
fi
if [[ "$detach" == true ]]; then
  args+=(--detach --wait --wait-timeout 120)
  docker compose "${args[@]}"
  printf 'Local API: http://localhost:8080\n'
  printf 'Health:    http://localhost:8080/health\n'
  printf 'Stop with: docker compose down\n'
else
  printf 'Starting in the foreground; press Ctrl-C to stop containers.\n'
  docker compose "${args[@]}"
fi
