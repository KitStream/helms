#!/usr/bin/env bash
#
# E2E test runner for the netbird Helm chart.
#
# Usage:
#   ci/scripts/e2e.sh <backend>
#
# Backends:
#   sqlite   — default SQLite storage (no external DB)
#   postgres — PostgreSQL deployed as a simple pod
#   mysql    — MySQL deployed as a simple pod
#
set -euo pipefail

BACKEND="${1:-sqlite}"
RELEASE="netbird-e2e"
NAMESPACE="netbird-e2e"
CHART="charts/netbird"
TIMEOUT="5m"

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

# ── Deploy database (if needed) ───────────────────────────────────────
deploy_postgres() {
  log "Deploying PostgreSQL..."
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
type: Opaque
stringData:
  POSTGRES_DB: netbird
  POSTGRES_USER: netbird
  POSTGRES_PASSWORD: testpassword
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
              command: ["pg_isready", "-U", "netbird"]
            initialDelaySeconds: 5
            periodSeconds: 3
EOF

  log "Waiting for PostgreSQL to be ready..."
  kubectl -n "$NAMESPACE" rollout status deployment/postgres --timeout=120s

  # Create the password secret for netbird
  kubectl -n "$NAMESPACE" create secret generic netbird-db-password \
    --from-literal=password="testpassword"
}

deploy_mysql() {
  log "Deploying MySQL..."
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
type: Opaque
stringData:
  MYSQL_DATABASE: netbird
  MYSQL_USER: netbird
  MYSQL_PASSWORD: testpassword
  MYSQL_ROOT_PASSWORD: rootpassword
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
spec:
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          envFrom:
            - secretRef:
                name: mysql-credentials
          ports:
            - containerPort: 3306
          readinessProbe:
            exec:
              command: ["mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-prootpassword"]
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 3
EOF

  log "Waiting for MySQL to be ready..."
  kubectl -n "$NAMESPACE" rollout status deployment/mysql --timeout=180s

  # Create the password secret for netbird
  kubectl -n "$NAMESPACE" create secret generic netbird-db-password \
    --from-literal=password="testpassword"
}

case "$BACKEND" in
  sqlite)
    log "Using SQLite — no external database needed"
    VALUES_FILE="$CHART/ci/e2e-values.yaml"
    ;;
  postgres)
    deploy_postgres
    VALUES_FILE="$CHART/ci/e2e-values-postgres.yaml"
    ;;
  mysql)
    deploy_mysql
    VALUES_FILE="$CHART/ci/e2e-values-mysql.yaml"
    ;;
  *)
    fail "Unknown backend: $BACKEND (expected: sqlite, postgres, mysql)"
    ;;
esac

# ── Install netbird chart ─────────────────────────────────────────────
log "Installing netbird chart with $BACKEND backend..."
helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --wait --timeout "$TIMEOUT"

# ── Verify rollout ────────────────────────────────────────────────────
log "Verifying deployments..."
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-server --timeout=120s
kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-dashboard --timeout=120s

log "Pod status:"
kubectl -n "$NAMESPACE" get pods -o wide

# ── Run helm test ─────────────────────────────────────────────────────
log "Running helm test..."
helm test "$RELEASE" -n "$NAMESPACE" --timeout 2m

log "E2E test with $BACKEND backend PASSED!"
