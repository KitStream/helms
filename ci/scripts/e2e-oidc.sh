#!/usr/bin/env bash
#
# E2E test runner for the netbird Helm chart — OIDC integration.
#
# Usage:
#   ci/scripts/e2e-oidc.sh <provider>
#
# Providers:
#   keycloak — Keycloak deployed in-cluster (quay.io/keycloak/keycloak:26.0)
#
set -euo pipefail

PROVIDER="${1:-keycloak}"
RELEASE="netbird-e2e"
NAMESPACE="netbird-e2e"
CHART="charts/netbird"
TIMEOUT="10m"

log()  { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Cleanup function ───────────────────────────────────────────────────
cleanup() {
  log "Cleaning up..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

# ── Create namespace ───────────────────────────────────────────────────
log "Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── Deploy Keycloak ──────────────────────────────────────────────────
deploy_keycloak() {
  log "Deploying Keycloak..."
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: keycloak
spec:
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: management
      port: 9000
      targetPort: 9000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.0
          args: ["start-dev"]
          env:
            - name: KC_HEALTH_ENABLED
              value: "true"
            - name: KEYCLOAK_ADMIN
              value: "admin"
            - name: KEYCLOAK_ADMIN_PASSWORD
              value: "admin"
          ports:
            - containerPort: 8080
            - containerPort: 9000
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 9000
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 20
EOF

  log "Waiting for Keycloak to be ready..."
  kubectl -n "$NAMESPACE" rollout status deployment/keycloak --timeout=300s
}

# ── Configure Keycloak realm via REST API ────────────────────────────
configure_keycloak() {
  log "Configuring Keycloak realm and clients..."

  # Run configuration from a pod inside the cluster
  kubectl -n "$NAMESPACE" run keycloak-setup --image=alpine:3.20 --restart=Never \
    --command -- sh -c '
    apk add --no-cache curl jq >/dev/null 2>&1

    KC_URL="http://keycloak.netbird-e2e.svc.cluster.local:8080"
    KC_MGMT_URL="http://keycloak.netbird-e2e.svc.cluster.local:9000"

    # Wait for Keycloak API (health endpoint is on management port 9000)
    echo "Waiting for Keycloak API..."
    for i in $(seq 1 60); do
      if curl -sf "$KC_MGMT_URL/health/ready" >/dev/null 2>&1; then
        echo "Keycloak API is ready"
        break
      fi
      if [ "$i" -eq 60 ]; then
        echo "FAIL: Keycloak not ready after 60 attempts"
        exit 1
      fi
      sleep 3
    done

    # Get admin token
    echo "Getting admin token..."
    ADMIN_TOKEN=$(curl -sf -X POST \
      "$KC_URL/realms/master/protocol/openid-connect/token" \
      -d "client_id=admin-cli" \
      -d "username=admin" \
      -d "password=admin" \
      -d "grant_type=password" | jq -r ".access_token")

    if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
      echo "FAIL: Could not get admin token"
      exit 1
    fi
    echo "Got admin token"

    # Create realm
    echo "Creating netbird realm..."
    curl -sf -X POST "$KC_URL/admin/realms" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"realm\":\"netbird\",\"enabled\":true}" || true

    # Create public client (for PKCE flow / direct grant testing)
    echo "Creating netbird-client (public)..."
    curl -sf -X POST "$KC_URL/admin/realms/netbird/clients" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\":\"netbird-client\",
        \"publicClient\":true,
        \"directAccessGrantsEnabled\":true,
        \"redirectUris\":[\"*\"],
        \"webOrigins\":[\"*\"],
        \"protocol\":\"openid-connect\"
      }"

    # Create confidential client (for IdP manager)
    echo "Creating netbird-backend (confidential)..."
    curl -sf -X POST "$KC_URL/admin/realms/netbird/clients" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"clientId\":\"netbird-backend\",
        \"publicClient\":false,
        \"serviceAccountsEnabled\":true,
        \"secret\":\"test-backend-secret\",
        \"directAccessGrantsEnabled\":false,
        \"protocol\":\"openid-connect\"
      }"

    # Create test user
    echo "Creating test user..."
    curl -sf -X POST "$KC_URL/admin/realms/netbird/users" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\":\"testuser\",
        \"enabled\":true,
        \"email\":\"test@netbird.test\",
        \"firstName\":\"Test\",
        \"lastName\":\"User\",
        \"credentials\":[{\"type\":\"password\",\"value\":\"testpassword\",\"temporary\":false}]
      }"

    echo "Keycloak configuration complete"
    exit 0
  '

  log "Waiting for Keycloak setup pod..."
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/keycloak-setup --timeout=60s 2>/dev/null || true
  kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/keycloak-setup --timeout=120s || {
    log "Keycloak setup pod logs:"
    kubectl -n "$NAMESPACE" logs keycloak-setup || true
    fail "Keycloak configuration failed"
  }
  log "Keycloak setup pod logs:"
  kubectl -n "$NAMESPACE" logs keycloak-setup || true
  kubectl -n "$NAMESPACE" delete pod keycloak-setup --ignore-not-found 2>/dev/null || true
}

# ── Create secrets ───────────────────────────────────────────────────
create_oidc_secrets() {
  log "Creating OIDC secrets..."
  kubectl -n "$NAMESPACE" create secret generic netbird-idp-secret \
    --from-literal=clientSecret="test-backend-secret"
}

# ── Provider dispatch ────────────────────────────────────────────────
case "$PROVIDER" in
  keycloak)
    deploy_keycloak
    configure_keycloak
    create_oidc_secrets
    VALUES_FILE="$CHART/ci/e2e-values-oidc-keycloak.yaml"
    ;;
  *)
    fail "Unknown OIDC provider: $PROVIDER (expected: keycloak)"
    ;;
esac

# ── Install netbird chart ─────────────────────────────────────────────
log "Installing netbird chart with OIDC ($PROVIDER)..."
if ! helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --timeout "$TIMEOUT"; then
  log "Helm install failed — dumping logs..."
  kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-server --all-containers --tail=100 2>/dev/null || true
  fail "Helm install failed"
fi

# ── Verify rollout ────────────────────────────────────────────────────
log "Verifying deployments..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-server --timeout=300s
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-dashboard --timeout=120s

log "Pod status:"
kubectl -n "$NAMESPACE" get pods -o wide

# ── Run helm test ─────────────────────────────────────────────────────
log "Running helm test..."
helm test "$RELEASE" -n "$NAMESPACE" --timeout 2m

# ── Verify OIDC middleware is active ─────────────────────────────────
# We verify the OIDC config was applied by checking that:
#   1. Unauthenticated requests return 401 (not 200 or 500)
#   2. Keycloak token acquisition works (realm + client configured)
# Full token-based auth testing is out of scope for the chart e2e:
# NetBird's embedded IdP layer re-signs tokens internally.
log "Verifying OIDC middleware is active..."
SVC_URL="http://$RELEASE-server.$NAMESPACE.svc.cluster.local:80"
KC_URL="http://keycloak.$NAMESPACE.svc.cluster.local:8080"

kubectl -n "$NAMESPACE" run oidc-test --image=alpine:3.20 --restart=Never \
  --command -- sh -c "
    apk add --no-cache curl jq >/dev/null 2>&1
    sleep 3

    echo '==> Test 1: Unauthenticated request should return 401...'
    HTTP_CODE=\$(curl -s -o /tmp/body -w '%{http_code}' '$SVC_URL/api/groups')
    echo \"HTTP status: \$HTTP_CODE\"
    echo \"Body: \$(cat /tmp/body | head -c 200)\"
    if [ \"\$HTTP_CODE\" != '401' ]; then
      echo \"FAIL: Expected HTTP 401, got \$HTTP_CODE\"
      exit 1
    fi
    echo 'PASS: Unauthenticated request returned 401 (OIDC middleware active)'

    echo ''
    echo '==> Test 2: Obtain access token via Keycloak direct grant...'
    TOKEN_RESPONSE=\$(curl -sf -X POST \
      '$KC_URL/realms/netbird/protocol/openid-connect/token' \
      -d 'client_id=netbird-client' \
      -d 'username=testuser' \
      -d 'password=testpassword' \
      -d 'grant_type=password' \
      -d 'scope=openid profile email')

    ACCESS_TOKEN=\$(echo \"\$TOKEN_RESPONSE\" | jq -r '.access_token')
    if [ -z \"\$ACCESS_TOKEN\" ] || [ \"\$ACCESS_TOKEN\" = 'null' ]; then
      echo 'FAIL: Could not obtain access token from Keycloak'
      echo \"Token response: \$(echo \"\$TOKEN_RESPONSE\" | head -c 500)\"
      exit 1
    fi
    echo 'PASS: Keycloak token acquisition succeeded'

    echo ''
    echo 'All OIDC e2e checks passed'
    exit 0
  "

log "Waiting for OIDC test pod..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/oidc-test --timeout=60s 2>/dev/null || true
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/oidc-test --timeout=120s || {
  log "OIDC test pod logs:"
  kubectl -n "$NAMESPACE" logs oidc-test || true
  log "Server logs:"
  kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-server --tail=50 || true
  fail "OIDC authentication test failed"
}
log "OIDC test pod logs:"
kubectl -n "$NAMESPACE" logs oidc-test || true
log "E2E test with OIDC ($PROVIDER) PASSED!"
