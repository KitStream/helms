.PHONY: lint unittest e2e e2e-setup e2e-teardown test

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
E2E_NS       := netbird-e2e

e2e-setup:
	@echo "==> Creating kind cluster $(E2E_CLUSTER)..."
	kind create cluster --name $(E2E_CLUSTER) --wait 60s 2>/dev/null || true
	kubectl cluster-info --context kind-$(E2E_CLUSTER)

e2e: e2e-setup
	@echo "==> Installing netbird chart..."
	helm install netbird-e2e charts/netbird \
		-n $(E2E_NS) --create-namespace \
		-f charts/netbird/ci/e2e-values.yaml \
		--wait --timeout 3m
	@echo "==> Verifying rollout..."
	kubectl -n $(E2E_NS) rollout status deployment/netbird-e2e-server --timeout=120s
	kubectl -n $(E2E_NS) rollout status deployment/netbird-e2e-dashboard --timeout=120s
	@echo "==> Running helm test..."
	helm test netbird-e2e -n $(E2E_NS) --timeout 2m
	@echo "==> E2E tests passed!"

e2e-teardown:
	helm uninstall netbird-e2e -n $(E2E_NS) --ignore-not-found 2>/dev/null || true
	kubectl delete namespace $(E2E_NS) --ignore-not-found 2>/dev/null || true
	kind delete cluster --name $(E2E_CLUSTER) 2>/dev/null || true

# ── Run all tests ──────────────────────────────────────────────────────
test: lint unittest

