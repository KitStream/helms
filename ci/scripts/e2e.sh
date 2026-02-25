#!/usr/bin/env bash
#
# E2E test runner for the netbird Helm chart (with PAT seeding).
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

# ── Generate PAT for testing ───────────────────────────────────────────
# NetBird PAT format: nbp_ (4) + secret (30) + base62(CRC32(secret)) (6) = 40 chars
generate_pat_secret() {
  log "Generating PAT secret for testing..."
  read -r PAT_TOKEN PAT_HASH < <(python3 -c "
import hashlib, base64, binascii

BASE62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
def base62_encode(num, length=6):
    r = []
    while num > 0:
        r.append(BASE62[num % 62])
        num //= 62
    return ''.join(reversed(r)).rjust(length, '0')

secret = 'TestSecretValue1234567890ABCDE'   # exactly 30 chars
crc = binascii.crc32(secret.encode()) & 0xFFFFFFFF
token = 'nbp_' + secret + base62_encode(crc)
h = base64.b64encode(hashlib.sha256(token.encode()).digest()).decode()
print(token, h)
")
  log "Test PAT token: $PAT_TOKEN (length=${#PAT_TOKEN})"
  log "Test PAT hash:  $PAT_HASH"
  kubectl -n "$NAMESPACE" create secret generic netbird-pat \
    --from-literal=token="$PAT_TOKEN" \
    --from-literal=hashedToken="$PAT_HASH"
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

# ── Create PAT secret ─────────────────────────────────────────────────
generate_pat_secret

# ── Install netbird chart ─────────────────────────────────────────────
log "Installing netbird chart with $BACKEND backend and PAT seeding..."
EXTRA_SETS=()
if [ "$BACKEND" = "sqlite" ]; then
  EXTRA_SETS+=(--set server.persistentVolume.enabled=true)
fi
if ! helm install "$RELEASE" "$CHART" \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set pat.enabled=true \
  --set pat.secret.secretName=netbird-pat \
  "${EXTRA_SETS[@]}" \
  --timeout "$TIMEOUT"; then
  log "Helm install failed — dumping PAT seed job logs..."
  kubectl -n "$NAMESPACE" logs job/"$RELEASE"-server-pat-seed --all-containers 2>/dev/null || true
  kubectl -n "$NAMESPACE" describe job/"$RELEASE"-server-pat-seed 2>/dev/null || true
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

# ── Wait for PAT seed job to complete ─────────────────────────────────
log "Waiting for PAT seed job to complete..."
kubectl -n "$NAMESPACE" wait --for=condition=complete \
  job/"$RELEASE"-server-pat-seed --timeout=180s || {
  log "PAT seed job logs:"
  kubectl -n "$NAMESPACE" logs job/"$RELEASE"-server-pat-seed --all-containers || true
  fail "PAT seed job did not complete"
}
# ── Verify PAT authentication ─────────────────────────────────────────
log "Verifying PAT authentication against API..."
# Re-derive the PAT_TOKEN (same deterministic generation as above)
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
SVC_URL="http://$RELEASE-server.$NAMESPACE.svc.cluster.local:80"
kubectl -n "$NAMESPACE" run pat-test --image=alpine:3.20 --restart=Never \
  --command -- sh -c "
    apk add --no-cache curl >/dev/null 2>&1
    sleep 3
    echo '==> Testing PAT auth on /api/groups...'
    HTTP_CODE=\$(curl -s -o /tmp/body -w '%{http_code}' \
      -H 'Authorization: Token $PAT_TOKEN' \
      '$SVC_URL/api/groups')
    echo \"HTTP status: \$HTTP_CODE\"
    echo \"Body: \$(cat /tmp/body | head -c 500)\"
    if [ \"\$HTTP_CODE\" = '200' ]; then
      echo 'PASS: PAT authentication accepted (200 OK)'
      exit 0
    else
      echo \"FAIL: Expected HTTP 200, got \$HTTP_CODE\"
      exit 1
    fi
  "
log "Waiting for PAT test pod..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/pat-test --timeout=60s 2>/dev/null || true
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/pat-test --timeout=60s || {
  log "PAT test pod logs:"
  kubectl -n "$NAMESPACE" logs pat-test || true
  fail "PAT authentication test failed"
}
log "PAT test pod logs:"
kubectl -n "$NAMESPACE" logs pat-test || true
log "E2E test with $BACKEND backend PASSED (including PAT seeding)!"
