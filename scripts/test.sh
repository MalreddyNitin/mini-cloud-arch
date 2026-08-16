#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [--backend | --frontend | --static | --lint-only]
                       [--no-install] [--help]

With no selector, runs all checks. The default path needs no cloud credentials.
EOF
}

run_backend=false
run_frontend=false
run_static=false
lint_only=false
install=true
selected=false

while (($#)); do
  case "$1" in
    --backend) run_backend=true; selected=true ;;
    --frontend) run_frontend=true; selected=true ;;
    --static) run_static=true; selected=true ;;
    --lint-only)
      run_backend=true
      run_frontend=true
      run_static=true
      lint_only=true
      selected=true
      ;;
    --no-install) install=false ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$selected" == false ]]; then
  run_backend=true
  run_frontend=true
  run_static=true
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python_bin=""
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
fi

if [[ "$run_backend" == true ]]; then
  [[ -n "$python_bin" ]] || { printf 'Python 3.12+ is required.\n' >&2; exit 1; }
  (
    cd apps/api
    if [[ "$install" == true ]]; then
      "$python_bin" -m pip install --disable-pip-version-check -r requirements-dev.lock
    fi
    "$python_bin" -m ruff check app tests migrations
    if [[ "$lint_only" == false ]]; then
      "$python_bin" -m mypy app
      "$python_bin" -m pytest
      DATABASE_URL='sqlite+pysqlite:///:memory:' \
        DATABASE_URL_DIRECT='sqlite+pysqlite:///:memory:' \
        "$python_bin" -m alembic upgrade head
    fi
  )
fi

if [[ "$run_frontend" == true ]]; then
  command -v npm >/dev/null 2>&1 || { printf 'npm is required.\n' >&2; exit 1; }
  (
    cd apps/web
    if [[ "$install" == true ]]; then
      npm ci
    fi
    npm run lint
    if [[ "$lint_only" == false ]]; then
      npm run typecheck
      npm test -- --run
      VITE_API_BASE_URL="${VITE_API_BASE_URL:-https://api.example.invalid}" npm run build
    fi
  )
fi

if [[ "$run_static" == true ]]; then
  [[ -n "$python_bin" ]] || { printf 'Python 3 is required for policy unit tests.\n' >&2; exit 1; }
  while IFS= read -r -d '' script; do
    bash -n "$script"
  done < <(find scripts infra -type f -name '*.sh' -print0)

  "$python_bin" -m unittest discover -s scripts/tests -p 'test_*.py'
  ./scripts/check-free-tier.sh --static

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose config --quiet
  else
    printf 'SKIP: docker compose config (Docker Compose unavailable)\n'
  fi
fi

printf 'Selected checks passed.\n'
