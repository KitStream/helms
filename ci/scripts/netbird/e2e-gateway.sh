#!/usr/bin/env bash
#
# E2E test for the netbird chart's Gateway API support.
#
# Installs Gateway API CRDs + Envoy Gateway on the kind cluster, provisions
# a Gateway, and verifies the chart's HTTPRoute/GRPCRoute resources attach
# successfully (Accepted=True) with the correct backend references.
#
# Scope: route integration only. The full peer-registration/PAT flow is
# already covered by ci/scripts/netbird/e2e.sh — this test focuses on the
# Gateway API surface added in #74.
#
set -euo pipefail

RELEASE="netbird-gateway-e2e"
NAMESPACE="netbird-gateway-e2e"
CHART="charts/netbird"
VALUES_FILE="$CHART/ci/e2e-values-gateway.yaml"
TIMEOUT="10m"

# Pinned versions so CI is reproducible.
GATEWAY_API_VERSION="v1.2.1"
ENVOY_GATEWAY_VERSION="v1.5.3"
ENVOY_NS="envoy-gateway-system"

log()  { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  log "Cleaning up..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  # Leave Envoy Gateway + CRDs installed to speed up re-runs on the same
  # kind cluster; the kind cluster itself is torn down by CI.
}
trap cleanup EXIT

# ── Install Gateway API CRDs ──────────────────────────────────────────
log "Installing Gateway API CRDs ($GATEWAY_API_VERSION)..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
# TCPRoute lives in the experimental channel (still v1alpha2).
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/experimental-install.yaml"

# ── Install Envoy Gateway ─────────────────────────────────────────────
log "Installing Envoy Gateway ($ENVOY_GATEWAY_VERSION)..."
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$ENVOY_GATEWAY_VERSION" \
  -n "$ENVOY_NS" \
  --create-namespace \
  --wait --timeout 5m

# ── Create netbird namespace ──────────────────────────────────────────
log "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── Provision a Gateway for the routes to attach to ───────────────────
log "Applying GatewayClass + Gateway..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: netbird-gateway
  namespace: $NAMESPACE
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.localhost"
      allowedRoutes:
        namespaces:
          from: Same
EOF

log "Waiting for Gateway to be Programmed..."
kubectl -n "$NAMESPACE" wait --for=condition=Programmed gateway/netbird-gateway --timeout=3m

# ── Generate PAT secret (chart requires pat.secret.secretName) ────────
generate_pat_secret() {
  log "Generating PAT secret..."
  PAT_TOKEN=$(python3 -c "
import binascii
BASE62='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
def b62(n,l=6):
    r=[]
    while n>0: r.append(BASE62[n%62]); n//=62
    return ''.join(reversed(r)).rjust(l,'0')
s='TestSecretValue1234567890ABCDE'
print('nbp_'+s+b62(binascii.crc32(s.encode())&0xFFFFFFFF))
")
  kubectl -n "$NAMESPACE" create secret generic netbird-pat \
    --from-literal=token="$PAT_TOKEN"
}
generate_pat_secret

# ── Install netbird chart ─────────────────────────────────────────────
log "Installing netbird chart with Gateway API routes enabled..."
if ! helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set pat.enabled=true \
  --set pat.secret.secretName=netbird-pat \
  --set server.persistentVolume.enabled=true \
  --timeout "$TIMEOUT"; then
  log "Helm install failed — dumping logs..."
  kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-server -c pat-seed 2>/dev/null || true
  fail "Helm install failed"
fi

log "Verifying deployments..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-server --timeout=300s
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-dashboard --timeout=120s

# ── Verify the routes attached to the Gateway ─────────────────────────
wait_route_accepted() {
  local kind="$1" name="$2"
  log "Waiting for $kind/$name to report Accepted=True..."
  for _ in $(seq 1 30); do
    # Route status uses parents[].conditions[type=Accepted].
    local accepted
    accepted=$(kubectl -n "$NAMESPACE" get "$kind" "$name" \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
    if [ "$accepted" = "True" ]; then
      log "  $kind/$name Accepted=True"
      return 0
    fi
    sleep 3
  done
  log "$kind/$name did NOT reach Accepted=True. Full status:"
  kubectl -n "$NAMESPACE" get "$kind" "$name" -o yaml | sed -n '/^status:/,$p' || true
  fail "$kind/$name was not accepted by Gateway"
}

wait_route_accepted httproute "$RELEASE-server"
wait_route_accepted httproute "$RELEASE-server-relay"
wait_route_accepted httproute "$RELEASE-dashboard"
wait_route_accepted grpcroute "$RELEASE-server-grpc"

# ── Confirm backendRefs auto-filled correctly ────────────────────────
assert_backend_ref() {
  local kind="$1" name="$2" expected_svc="$3"
  local svc
  svc=$(kubectl -n "$NAMESPACE" get "$kind" "$name" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].name}')
  if [ "$svc" != "$expected_svc" ]; then
    fail "$kind/$name backendRefs[0].name = '$svc' (expected '$expected_svc')"
  fi
  log "  $kind/$name backendRefs[0].name = $svc ✓"
}

assert_backend_ref httproute "$RELEASE-server"       "$RELEASE-server"
assert_backend_ref httproute "$RELEASE-server-relay" "$RELEASE-server"
assert_backend_ref httproute "$RELEASE-dashboard"    "$RELEASE-dashboard"
assert_backend_ref grpcroute "$RELEASE-server-grpc"  "$RELEASE-server"

# ── Confirm mutual-exclusion validation trips ────────────────────────
log "Verifying template validation: enabling Ingress + HTTPRoute should fail..."
if helm template "$RELEASE" "$CHART" \
  -f "$VALUES_FILE" \
  --set server.ingress.enabled=true > /dev/null 2>&1; then
  fail "Template rendered with both Ingress and HTTPRoute enabled — mutual-exclusion check missing"
fi
log "  mutual-exclusion validation correctly rejects the combination ✓"

log "E2E Gateway API test PASSED — routes accepted, backendRefs auto-filled, exclusion validated."
