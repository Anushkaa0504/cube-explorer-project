# Cube Explorer – common tasks
# Run `make help` to see what's available.

SHELL := /bin/bash
COMPOSE := docker compose
CUBE_SVC := cube
BASE := http://localhost:4000

.DEFAULT_GOAL := help

# -- Meta ---------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# -- Lifecycle ----------------------------------------------------------------

.PHONY: up
up: ## Start Cube + Cube Store in the background
	$(COMPOSE) up -d
	@echo
	@echo "Cube is starting. Tail logs with: make logs"
	@echo "Playground:     http://localhost:4000"
	@echo "GraphQL:        http://localhost:4000/cubejs-api/graphql"
	@echo "SQL API (psql): postgres://cube:cube@localhost:15432/cube"

.PHONY: down
down: ## Stop and remove containers (keeps Cube Store data volume)
	$(COMPOSE) down

.PHONY: nuke
nuke: ## Stop containers AND wipe the Cube Store pre-aggregation volume
	$(COMPOSE) down -v

.PHONY: restart
restart: down up ## Restart everything

.PHONY: rebuild
rebuild: ## Pull latest images and recreate containers
	$(COMPOSE) pull
	$(COMPOSE) up -d --force-recreate

# -- Observability ------------------------------------------------------------

.PHONY: logs
logs: ## Tail logs from the Cube container
	$(COMPOSE) logs -f $(CUBE_SVC)

.PHONY: logs-all
logs-all: ## Tail logs from every service
	$(COMPOSE) logs -f

.PHONY: ps
ps: ## Show running containers
	$(COMPOSE) ps

.PHONY: ready
ready: ## Block until the Playground answers HTTP 200
	@echo "Waiting for Cube to become ready at $(BASE) ..."
	@for i in $$(seq 1 60); do \
	  if curl -fs $(BASE)/readyz >/dev/null 2>&1 || curl -fs $(BASE)/livez >/dev/null 2>&1 || curl -fs $(BASE) >/dev/null 2>&1; then \
	    echo "Cube is ready."; exit 0; \
	  fi; \
	  sleep 2; \
	done; \
	echo "Cube did not become ready within 2 minutes."; exit 1

# -- Inside the container -----------------------------------------------------

.PHONY: shell
shell: ## Open a shell inside the Cube container
	$(COMPOSE) exec $(CUBE_SVC) /bin/sh

# -- Validation & APIs --------------------------------------------------------

CUBE_SYNC_CACHE := $(HOME)/.cache/cube-explorer/model-cubes

.PHONY: sync-identity sync-identity-install
sync-identity: ## Regenerate model/cubes/*.js from JSON sources (or ~/.cache if not writable)
	@node scripts/build_js_cubes.js

sync-identity-install: ## Build model/cubes-js/ via Docker (when local node cannot write)
	@mkdir -p $(CUBE_SYNC_CACHE)
	@node scripts/build_js_cubes.js --out-dir "$(CUBE_SYNC_CACHE)" || true
	@docker run --rm -u 0 \
	  -v "$(CURDIR):/w" -w /w \
	  node:20-slim \
	  node scripts/build_js_cubes.js --out-dir /w/model/cubes-js
	@echo "Built model/cubes-js/ (Cube uses this; legacy model/cubes/*.yml optional to delete)"


.PHONY: remove-legacy-yaml
remove-legacy-yaml: ## Delete stale model/cubes/*.yml (run as user that owns model/cubes/)
	@rm -fv model/cubes/users.yml model/cubes/accounts.yml model/cubes/categories.yml \
	  model/cubes/merchants.yml model/cubes/transactions.yml
	@echo "Removed legacy YAML cubes from model/cubes/"

.PHONY: validate
validate: sync-identity ## Lint JS cubes + identity.json (offline)
	@for f in model/cubes-js/*.js; do node --check "$$f" && echo "OK $$f"; done
	@python3 -c "import yaml, glob; \
[print('OK ', f) for f in sorted(glob.glob('model/views/**/*.yml', recursive=True)) \
 if (yaml.safe_load(open(f)) or True)]; \
print('views YAML OK')"
	@node --check cube.js && echo 'cube.js OK'
	@node -e "JSON.parse(require('fs').readFileSync('model/cubes/identity.json')); console.log('model/cubes/identity.json OK')"
	@python3 -c "import ast; ast.parse(open('model/globals.py').read()); print('globals.py OK')"
	@$(COMPOSE) config --quiet && echo "docker-compose.yml OK"

.PHONY: meta
meta: ## Print the compiled meta (list of cubes/views) via REST API
	@curl -s $(BASE)/cubejs-api/v1/meta | jq '{cubes: .cubes | map(.name)}'

.PHONY: test test-auth access-readme
test: ## Run the end-to-end API smoke test
	./scripts/test_apis.sh

access-readme: ## Open model/README.md (users, roles, policies, curl+jq)
	@sed -n '1,60p' model/README.md

test-auth: ## Smoke test JWT users from model/cubes/identity.json (Cube must be up)
	@chmod +x scripts/test_auth.sh
	./scripts/test_auth.sh

.PHONY: jwt jwt-user auth-users
jwt: ## Print JWT for user 1 (roles from identity.json via cube.js)
	@$(MAKE) jwt-user UID=1

jwt-user: ## Print JWT for user UID. Usage: make jwt-user UID=3
	@python3 scripts/sign_jwt.py $(if $(UID),$(UID),1)

auth-users: ## List demo users and roles from model/cubes/identity.json
	@jq '.users[] | {id, email, roles}' model/cubes/identity.json
	@echo "--- roles ---"
	@jq '.roles | keys' model/cubes/identity.json

.PHONY: rls
rls: ## Demo row-level security (user 1 = customer; run transactions.posted_count not orders)
	@TOKEN=$$(python3 scripts/sign_jwt.py 1); \
	echo "Alan (user 2, analyst):"; \
	curl -s -G $(BASE)/cubejs-api/v1/load -H "Authorization: $$(python3 scripts/sign_jwt.py 2)" \
	  --data-urlencode 'query={"measures":["transactions.posted_count"]}' | jq '.data[0]'; \
	echo "Ada (user 1, customer):"; \
	curl -s -G $(BASE)/cubejs-api/v1/load -H "Authorization: $$TOKEN" \
	  --data-urlencode 'query={"measures":["transactions.posted_count"]}' | jq '.data[0]'

.PHONY: sql
sql: ## Open a psql session against the Cube SQL API
	PGPASSWORD=cube psql postgres://cube@localhost:15432/cube

.PHONY: q
q: ## REST query helper. Usage: make q ARGS='-a -u 1 "{\"measures\":[\"transactions.posted_count\"]}"'
	@./scripts/q $(ARGS)

.PHONY: as-user
as-user: ## Query as user. Usage: make as-user USER=1 Q='{"dimensions":["users.email"],"limit":2}'
	@bash scripts/as-user.sh $(USER) '$(Q)'

# -- MCP (Model Context Protocol) ---------------------------------------------

.PHONY: mcp-install
mcp-install: ## Create the MCP server venv and install deps
	python3 -m venv mcp_server/.venv
	mcp_server/.venv/bin/pip install -r mcp_server/requirements.txt

.PHONY: mcp
mcp: ## Run the Cube MCP server in the foreground (stdio mode)
	mcp_server/.venv/bin/python mcp_server/cube_mcp.py

.PHONY: mcp-test
mcp-test: ## Send a sample query through the MCP server to confirm it works
	@mcp_server/.venv/bin/python mcp_server/test_client.py

# -- Prefect (Orchestration API) --------------------------------------------
# Venv under ~/.cache so modernadmin (or any user) can install without write
# access to anushkarakesh-owned prefect/.venv on disk.

PREFECT_CACHE := $(HOME)/.cache/cube-explorer
PREFECT_VENV  := $(PREFECT_CACHE)/prefect-venv
PREFECT_PY    := $(PREFECT_VENV)/bin/python

.PHONY: prefect-install prefect-query prefect-build
prefect-install: ## Install prefect-cubejs into ~/.cache/cube-explorer/prefect-venv
	@mkdir -p $(PREFECT_CACHE)
	python3 -m venv $(PREFECT_VENV)
	$(PREFECT_VENV)/bin/pip install -r prefect/requirements.txt
	@echo "Prefect venv: $(PREFECT_VENV)"

prefect-query: ## Run Prefect flow: query transactions via /v1/load
	@test -x $(PREFECT_PY) || { echo "Run: make prefect-install"; exit 1; }
	$(PREFECT_PY) prefect/cube_query.py

prefect-build: ## Run Prefect flow: rebuild pre-aggs via /v1/pre-aggregations/jobs
	@test -x $(PREFECT_PY) || { echo "Run: make prefect-install"; exit 1; }
	$(PREFECT_PY) prefect/cube_build.py

# -- Rust CLI -----------------------------------------------------------------
# Build in $HOME/.cache so any user (e.g. modernadmin) can compile without
# write access to anushkarakesh-owned project files (Cargo.lock, target/).

RUST_CACHE := $(HOME)/.cache/cube-explorer
RUST_BUILD := $(RUST_CACHE)/cube-cli
RUST_CLI   := $(RUST_BUILD)/target/release/cube-cli
RUST_SRC   := rust/cube-cli

.PHONY: rust-sync
rust-sync: ## Copy crate sources into a writable build dir under ~/.cache
	@mkdir -p $(RUST_BUILD)
	@cp -f $(RUST_SRC)/Cargo.toml $(RUST_BUILD)/
	@cp -rf $(RUST_SRC)/src $(RUST_BUILD)/
	@if [ -f $(RUST_SRC)/Cargo.lock ]; then cp -f $(RUST_SRC)/Cargo.lock $(RUST_BUILD)/; fi

.PHONY: rust-build
rust-build: rust-sync ## Build cube-cli (release; needs `cargo` on PATH)
	@command -v cargo >/dev/null 2>&1 || { \
	  echo "cargo not found. Install: https://rustup.rs  OR run: make rust-build-docker"; \
	  exit 1; \
	}
	cd $(RUST_BUILD) && cargo build --release
	@echo "Binary: $(RUST_CLI)"

.PHONY: rust-build-docker
rust-build-docker: ## Build cube-cli via Docker (no local Rust needed)
	docker build -t cube-cli rust/cube-cli
	@echo "Run: docker run --rm --network host -v $$(pwd):/workspace -w /workspace cube-cli meta"

.PHONY: rust-meta
rust-meta: rust-build ## List cubes via the Rust CLI
	@$(RUST_CLI) meta

.PHONY: rust-query
rust-query: rust-build ## Example query via Rust CLI
	@$(RUST_CLI) query '{"measures":["transactions.posted_count"]}'

.PHONY: rust-test
rust-test: rust-build ## User 1 JWT query via Rust CLI (RLS: customer in users.json)
	@$(RUST_CLI) query --user-id 1 '{"measures":["transactions.posted_count"]}'

# -- Browser helpers ----------------------------------------------------------

.PHONY: playground
playground: ## Open the Developer Playground in your default browser
	@xdg-open $(BASE) 2>/dev/null || open $(BASE) 2>/dev/null || echo "Open $(BASE) manually"

.PHONY: dashboard
dashboard: ## Open the local HTML dashboard in your default browser
	@xdg-open frontend/index.html 2>/dev/null || open frontend/index.html 2>/dev/null || echo "Open frontend/index.html manually"
