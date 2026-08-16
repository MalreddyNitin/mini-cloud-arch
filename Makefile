SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help dev dev-detached down logs test test-backend test-frontend lint typecheck build smoke smoke-full load-test check-free-tier backup-db compose-config

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

dev: ## Build and run local PostgreSQL + API in the foreground
	./scripts/dev.sh

dev-detached: ## Build and run local PostgreSQL + API in the background
	./scripts/dev.sh --detach

down: ## Stop the local stack without deleting its database volume
	docker compose down

logs: ## Follow local API and database logs
	docker compose logs --follow api db

test: ## Install locked dependencies and run all local checks/tests
	./scripts/test.sh

test-backend: ## Run backend lint, type checks, tests, and migration sanity
	./scripts/test.sh --backend

test-frontend: ## Run frontend lint, type checks, tests, and build
	./scripts/test.sh --frontend

lint: ## Run backend/frontend linters and shell syntax checks
	./scripts/test.sh --lint-only

typecheck: ## Run backend and frontend type checks
	cd apps/api && python -m mypy app
	cd apps/web && npm run typecheck

build: ## Build the frontend and API container
	cd apps/web && VITE_API_BASE_URL="$${VITE_API_BASE_URL:-https://api.example.invalid}" npm run build
	docker build --tag zero-cloud-api:local apps/api

smoke: ## Smoke-test local health/readiness and read paths
	./scripts/smoke-test.sh --api-url "$${API_URL:-http://localhost:8080}" --web-url "$${WEB_URL:-http://localhost:5173}"

smoke-full: ## Exercise mutations and a 10 MiB direct R2 transfer (credentials required)
	./scripts/smoke-test.sh --api-url "$${API_URL:-http://localhost:8080}" --web-url "$${WEB_URL:-http://localhost:5173}" --full

load-test: ## Run a bounded read-only local probe (override with LOAD_ARGS)
	./scripts/load-test.sh --api-url "$${API_URL:-http://localhost:8080}" $${LOAD_ARGS:-}

check-free-tier: ## Validate static guardrails; add provider flags for live checks
	./scripts/check-free-tier.sh --static

backup-db: ## Create a local pg_dump; use BACKUP_ARGS for optional R2 upload
	./scripts/backup-db.sh $${BACKUP_ARGS:-}

compose-config: ## Validate the local Compose model
	docker compose config --quiet
