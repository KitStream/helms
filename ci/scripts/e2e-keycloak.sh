#!/usr/bin/env bash
#
# E2E test runner for the keycloak Helm chart.
#
# Usage:
#   ci/scripts/e2e-keycloak.sh <scenario>
#
# Scenarios:
#   dev       — embedded H2 dev mode (single replica, no external DB)
#   postgres  — PostgreSQL backend (single replica)
#   replicas  — multi-replica with kubernetes (dns-ping) cache stack
#
set -euo pipefail

SCENARIO="${1:-dev}"
RELEASE="keycloak-e2e"
NAMESPACE="keycloak-e2e"
CHART="charts/keycloak"
TIMEOUT="10m"
ADMIN_USER="admin"
ADMIN_PASSWORD="e2e-test-password-123"

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

# ── Create admin password secret ─────────────────────────────────────
log "Creating admin password secret..."
kubectl -n "$NAMESPACE" create secret generic keycloak-admin-password \
  --from-literal=password="$ADMIN_PASSWORD"

# ── Deploy PostgreSQL (if needed) ────────────────────────────────────
deploy_postgres() {
  log "Deploying PostgreSQL..."
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
type: Opaque
stringData:
  POSTGRES_DB: keycloak
  POSTGRES_USER: keycloak
  POSTGRES_PASSWORD: "test-db-password"
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          envFrom:
            - secretRef:
                name: postgres-credentials
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "keycloak"]
            initialDelaySeconds: 5
            periodSeconds: 3
EOF

  log "Waiting for PostgreSQL to be ready..."
  kubectl -n "$NAMESPACE" rollout status deployment/postgres --timeout=120s

  # Create the password secret for keycloak
  kubectl -n "$NAMESPACE" create secret generic keycloak-db-password \
    --from-literal=password='test-db-password'
}

# ── Scenario dispatch ────────────────────────────────────────────────
EXTRA_SETS=()
case "$SCENARIO" in
  dev)
    log "Using dev mode — no external database"
    VALUES_FILE="$CHART/ci/e2e-values.yaml"
    ;;
  postgres)
    deploy_postgres
    VALUES_FILE="$CHART/ci/e2e-values-postgres.yaml"
    ;;
  replicas)
    deploy_postgres
    VALUES_FILE="$CHART/ci/e2e-values-replicas.yaml"
    ;;
  *)
    fail "Unknown scenario: $SCENARIO (expected: dev, postgres, replicas)"
    ;;
esac

# ── Install keycloak chart ───────────────────────────────────────────
log "Installing keycloak chart with $SCENARIO scenario..."
if ! helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  "${EXTRA_SETS[@]}" \
  --timeout "$TIMEOUT"; then
  log "Helm install failed — dumping logs..."
  kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-keycloak --all-containers --tail=100 2>/dev/null || true
  fail "Helm install failed"
fi

# ── Verify rollout ───────────────────────────────────────────────────
log "Verifying deployment..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-keycloak --timeout=600s

log "Pod status:"
kubectl -n "$NAMESPACE" get pods -o wide

# ── Run helm test ────────────────────────────────────────────────────
log "Running helm test..."
helm test "$RELEASE" -n "$NAMESPACE" --timeout 5m

# ── Verify REST API access ───────────────────────────────────────────
log "Verifying Keycloak REST API..."
SVC_URL="http://$RELEASE-keycloak.$NAMESPACE.svc.cluster.local"
MGMT_URL="$SVC_URL:9000"
HTTP_URL="$SVC_URL:8080"

kubectl -n "$NAMESPACE" run api-test --image=alpine:3.20 --restart=Never \
  --env="HTTP_URL=$HTTP_URL" \
  --env="MGMT_URL=$MGMT_URL" \
  --env="ADMIN_USER=$ADMIN_USER" \
  --env="ADMIN_PASSWORD=$ADMIN_PASSWORD" \
  --command -- sh -c '
    apk add --no-cache curl jq >/dev/null 2>&1
    sleep 3

    echo "==> Test 1: Health endpoint returns UP..."
    HEALTH=$(curl -sf "$MGMT_URL/health/ready" 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q "UP"; then
      echo "PASS: Health check returned UP"
    else
      echo "FAIL: Health check did not return UP"
      echo "Response: $HEALTH"
      exit 1
    fi

    echo ""
    echo "==> Test 2: Metrics endpoint is accessible..."
    METRICS=$(curl -sf "$MGMT_URL/metrics" 2>/dev/null | head -5 || echo "")
    if [ -n "$METRICS" ]; then
      echo "PASS: Metrics endpoint returned data"
    else
      echo "FAIL: Metrics endpoint returned empty response"
      exit 1
    fi

    echo ""
    echo "==> Test 3: OIDC discovery endpoint..."
    OIDC=$(curl -sf "$HTTP_URL/realms/master/.well-known/openid-configuration" 2>/dev/null || echo "")
    ISSUER=$(echo "$OIDC" | jq -r ".issuer // empty" 2>/dev/null || echo "")
    if [ -n "$ISSUER" ]; then
      echo "PASS: OIDC discovery returned issuer: $ISSUER"
    else
      echo "FAIL: OIDC discovery did not return issuer"
      echo "Response: $(echo "$OIDC" | head -c 300)"
      exit 1
    fi

    echo ""
    echo "==> Test 4: Obtain admin access token..."
    TOKEN_RESP=$(curl -sf -X POST \
      "$HTTP_URL/realms/master/protocol/openid-connect/token" \
      -d "client_id=admin-cli" \
      -d "username=$ADMIN_USER" \
      -d "password=$ADMIN_PASSWORD" \
      -d "grant_type=password" 2>/dev/null || echo "")
    ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r ".access_token // empty" 2>/dev/null || echo "")
    if [ -z "$ACCESS_TOKEN" ]; then
      echo "FAIL: Could not obtain admin access token"
      echo "Response: $(echo "$TOKEN_RESP" | head -c 500)"
      exit 1
    fi
    echo "PASS: Admin token obtained"

    echo ""
    echo "==> Test 5: Admin REST API — list realms..."
    REALMS=$(curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$HTTP_URL/admin/realms" 2>/dev/null || echo "")
    REALM_COUNT=$(echo "$REALMS" | jq "length" 2>/dev/null || echo "0")
    if [ "$REALM_COUNT" -ge 1 ]; then
      echo "PASS: Admin API returned $REALM_COUNT realm(s)"
    else
      echo "FAIL: Admin API returned no realms"
      echo "Response: $(echo "$REALMS" | head -c 500)"
      exit 1
    fi

    echo ""
    echo "==> Test 6: Admin REST API — create a test realm..."
    CREATE_RESP=$(curl -s -o /tmp/create-body -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      "$HTTP_URL/admin/realms" \
      -d "{\"realm\":\"e2e-test\",\"enabled\":true}")
    if [ "$CREATE_RESP" = "201" ]; then
      echo "PASS: Created e2e-test realm (HTTP 201)"
    else
      echo "FAIL: Could not create realm (HTTP $CREATE_RESP)"
      cat /tmp/create-body | head -c 300
      exit 1
    fi

    echo ""
    echo "==> Test 7: Admin REST API — create a client in test realm..."
    CLIENT_RESP=$(curl -s -o /tmp/client-body -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      "$HTTP_URL/admin/realms/e2e-test/clients" \
      -d "{\"clientId\":\"e2e-client\",\"publicClient\":true,\"directAccessGrantsEnabled\":true}")
    if [ "$CLIENT_RESP" = "201" ]; then
      echo "PASS: Created e2e-client (HTTP 201)"
    else
      echo "FAIL: Could not create client (HTTP $CLIENT_RESP)"
      cat /tmp/client-body | head -c 300
      exit 1
    fi

    echo ""
    echo "==> Test 8: Admin REST API — create a user in test realm..."
    USER_RESP=$(curl -s -o /tmp/user-body -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      "$HTTP_URL/admin/realms/e2e-test/users" \
      -d "{\"username\":\"testuser\",\"enabled\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"testpass\",\"temporary\":false}]}")
    if [ "$USER_RESP" = "201" ]; then
      echo "PASS: Created testuser (HTTP 201)"
    else
      echo "FAIL: Could not create user (HTTP $USER_RESP)"
      cat /tmp/user-body | head -c 300
      exit 1
    fi

    echo ""
    echo "All API tests PASSED"
    exit 0
  '

log "Waiting for API test pod..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/api-test --timeout=60s 2>/dev/null || true
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/api-test --timeout=180s || {
  log "API test pod logs:"
  kubectl -n "$NAMESPACE" logs api-test || true
  log "Keycloak pod logs (last 50 lines):"
  kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-keycloak --tail=50 || true
  fail "API tests failed"
}
log "API test pod logs:"
kubectl -n "$NAMESPACE" logs api-test || true

# ── Multi-replica verification ───────────────────────────────────────
if [ "$SCENARIO" = "replicas" ]; then
  log "Verifying multi-replica deployment..."
  READY_REPLICAS=$(kubectl -n "$NAMESPACE" get deployment "$RELEASE"-keycloak \
    -o jsonpath='{.status.readyReplicas}')
  DESIRED_REPLICAS=$(kubectl -n "$NAMESPACE" get deployment "$RELEASE"-keycloak \
    -o jsonpath='{.spec.replicas}')
  log "Replicas: $READY_REPLICAS/$DESIRED_REPLICAS ready"
  if [ "$READY_REPLICAS" != "$DESIRED_REPLICAS" ]; then
    fail "Not all replicas are ready: $READY_REPLICAS/$DESIRED_REPLICAS"
  fi
  log "PASS: All $DESIRED_REPLICAS replicas are ready"

  # Verify that each pod is healthy individually
  log "Checking health of each replica..."
  PODS=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[*].metadata.name}')
  for POD in $PODS; do
    POD_IP=$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.podIP}')
    kubectl -n "$NAMESPACE" run "health-check-${POD##*-}" --image=alpine:3.20 --restart=Never --rm -i \
      --command -- sh -c "
        wget -q -O - --timeout=10 http://$POD_IP:9000/health/ready 2>/dev/null | grep -q UP && echo 'PASS: $POD is healthy' || { echo 'FAIL: $POD is not healthy'; exit 1; }
      " || fail "Health check failed for pod $POD"
  done
  log "PASS: All replicas are individually healthy"
fi

log "E2E test with $SCENARIO scenario PASSED!"
