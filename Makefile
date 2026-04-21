.PHONY: lint unittest e2e e2e-netbird e2e-sqlite e2e-postgres e2e-mysql e2e-gateway e2e-oidc-keycloak e2e-oidc-zitadel e2e-keycloak e2e-keycloak-dev e2e-keycloak-postgres e2e-keycloak-replicas e2e-setup e2e-teardown test compat-matrix

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

# ── NetBird E2E ─────────────────────────────────────────────────────────
e2e-sqlite: e2e-setup
	ci/scripts/netbird/e2e.sh sqlite

e2e-postgres: e2e-setup
	ci/scripts/netbird/e2e.sh postgres

e2e-mysql: e2e-setup
	ci/scripts/netbird/e2e.sh mysql

e2e-gateway: e2e-setup
	ci/scripts/netbird/e2e-gateway.sh

e2e-oidc-keycloak: e2e-setup
	ci/scripts/netbird/e2e-oidc.sh keycloak

e2e-oidc-zitadel: e2e-setup
	ci/scripts/netbird/e2e-oidc.sh zitadel

e2e-netbird: e2e-setup
	ci/scripts/netbird/e2e.sh sqlite
	ci/scripts/netbird/e2e.sh postgres
	ci/scripts/netbird/e2e.sh mysql
	ci/scripts/netbird/e2e-gateway.sh
	ci/scripts/netbird/e2e-oidc.sh keycloak
	ci/scripts/netbird/e2e-oidc.sh zitadel

# ── Keycloak E2E ────────────────────────────────────────────────────────
e2e-keycloak-dev: e2e-setup
	ci/scripts/keycloak/e2e.sh dev

e2e-keycloak-postgres: e2e-setup
	ci/scripts/keycloak/e2e.sh postgres

e2e-keycloak-replicas: e2e-setup
	ci/scripts/keycloak/e2e.sh replicas

e2e-keycloak: e2e-setup
	ci/scripts/keycloak/e2e.sh dev
	ci/scripts/keycloak/e2e.sh postgres
	ci/scripts/keycloak/e2e.sh replicas

# ── All E2E ─────────────────────────────────────────────────────────────
e2e: e2e-netbird e2e-keycloak

e2e-teardown:
	kind delete cluster --name $(E2E_CLUSTER) 2>/dev/null || true

# ── Compatibility Matrix ──────────────────────────────────────────────
compat-matrix: e2e-setup
	ci/scripts/netbird/compat-matrix.sh

# ── Run all tests ──────────────────────────────────────────────────────
test: lint unittest
