.PHONY: lint unittest e2e e2e-sqlite e2e-postgres e2e-mysql e2e-oidc-keycloak e2e-oidc-zitadel e2e-setup e2e-teardown test

CHARTS := $(wildcard charts/*)

# ── Lint ────────────────────────────────────────────────────────────────
lint:
	@for chart in $(CHARTS); do \
		echo "==> Linting $${chart}..."; \
		helm lint "$${chart}"; \
	done

# ── Unit Tests (helm-unittest) ──────────────────────────────────────────
unittest:
	@for chart in $(CHARTS); do \
		if [ -d "$${chart}/tests" ]; then \
			echo "==> Testing $${chart}..."; \
			helm unittest "$${chart}"; \
		fi; \
	done

# ── E2E Tests (kind) ───────────────────────────────────────────────────
E2E_CLUSTER  := helms-e2e

e2e-setup:
	@echo "==> Creating kind cluster $(E2E_CLUSTER)..."
	kind create cluster --name $(E2E_CLUSTER) --wait 60s 2>/dev/null || true
	kubectl cluster-info --context kind-$(E2E_CLUSTER)

e2e-sqlite: e2e-setup
	ci/scripts/e2e.sh sqlite

e2e-postgres: e2e-setup
	ci/scripts/e2e.sh postgres

e2e-mysql: e2e-setup
	ci/scripts/e2e.sh mysql

e2e-oidc-keycloak: e2e-setup
	ci/scripts/e2e-oidc.sh keycloak

e2e-oidc-zitadel: e2e-setup
	ci/scripts/e2e-oidc.sh zitadel

e2e: e2e-setup
	ci/scripts/e2e.sh sqlite
	ci/scripts/e2e.sh postgres
	ci/scripts/e2e.sh mysql
	ci/scripts/e2e-oidc.sh keycloak
	ci/scripts/e2e-oidc.sh zitadel

e2e-teardown:
	kind delete cluster --name $(E2E_CLUSTER) 2>/dev/null || true

# ── Run all tests ──────────────────────────────────────────────────────
test: lint unittest
