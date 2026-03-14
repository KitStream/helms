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
  # NOTE: POSTGRES_DB is intentionally omitted so the "netbird" database does
  # NOT exist on startup.  Initium's create_if_missing must create it — this
  # is the production-like path we want to exercise in e2e tests.
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
type: Opaque
stringData:
  POSTGRES_USER: netbird
  POSTGRES_PASSWORD: "test%40pass"
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
    --from-literal=password='test%40pass'
}

deploy_mysql() {
  log "Deploying MySQL..."
  # NOTE: MYSQL_DATABASE is intentionally omitted so the "netbird" database
  # does NOT exist on startup.  Initium's create_if_missing must create it.
  # Without MYSQL_DATABASE the image won't create MYSQL_USER either, so the
  # chart connects as root (see e2e-values-mysql.yaml).
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: mysql-credentials
type: Opaque
stringData:
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
    --from-literal=password='rootpassword'
}

# ── Generate PAT for testing ───────────────────────────────────────────
# NetBird PAT format: nbp_ (4) + secret (30) + base62(CRC32(secret)) (6) = 40 chars
generate_pat_secret() {
  log "Generating PAT secret for testing..."
  PAT_TOKEN=$(python3 -c "
import binascii

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
print(token)
")
  log "Test PAT token: $PAT_TOKEN (length=${#PAT_TOKEN})"
  kubectl -n "$NAMESPACE" create secret generic netbird-pat \
    --from-literal=token="$PAT_TOKEN"
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
  log "Helm install failed — dumping logs..."
  if [ "$BACKEND" = "sqlite" ]; then
    log "PAT seed sidecar logs:"
    kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-server -c pat-seed 2>/dev/null || true
  else
    log "PAT seed job logs:"
    kubectl -n "$NAMESPACE" logs job/"$RELEASE"-server-pat-seed --all-containers 2>/dev/null || true
    kubectl -n "$NAMESPACE" describe job/"$RELEASE"-server-pat-seed 2>/dev/null || true
  fi
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

# ── Wait for PAT seed to complete ─────────────────────────────────────
if [ "$BACKEND" = "sqlite" ]; then
  # SQLite: PAT seed runs as a native sidecar (init container with
  # restartPolicy: Always) in the server pod. The sidecar stays alive
  # after seeding (--sidecar flag), so we check its logs for the
  # "seed execution completed" message rather than waiting for
  # container termination.
  log "Waiting for PAT seed native sidecar to complete seeding..."
  for i in $(seq 1 60); do
    LOGS=$(kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-server -c pat-seed 2>/dev/null || echo "")
    if echo "$LOGS" | grep -q "seed execution completed"; then
      log "PAT seed sidecar completed seeding successfully"
      break
    fi
    if [ "$i" -eq 60 ]; then
      log "PAT seed sidecar logs:"
      echo "$LOGS"
      fail "PAT seed sidecar did not complete seeding within timeout"
    fi
    sleep 3
  done
else
  # External DB: PAT seed runs as a separate hook Job.
  log "Waiting for PAT seed job to complete..."
  kubectl -n "$NAMESPACE" wait --for=condition=complete \
    job/"$RELEASE"-server-pat-seed --timeout=180s || {
    log "PAT seed job logs:"
    kubectl -n "$NAMESPACE" logs job/"$RELEASE"-server-pat-seed --all-containers || true
    fail "PAT seed job did not complete"
  }
fi
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

# ── Wait for API provisioning (All group + default policy) ───────────
# The api-provision sidecar/container creates these via REST API after
# the DB seed completes. For SQLite (sidecar), this runs asynchronously
# so we need to poll until the All group appears.
log "Waiting for API provisioning to complete (All group)..."
kubectl -n "$NAMESPACE" run provision-check --image=alpine:3.20 --restart=Never --rm -i \
  --command -- sh -c "
    for i in \$(seq 1 60); do
      GROUPS=\$(wget -q -O - --header 'Authorization: Token $PAT_TOKEN' '$SVC_URL/api/groups' 2>/dev/null) || true
      if echo \"\$GROUPS\" | grep -q '\"name\":\"All\"'; then
        echo 'All group is ready'
        exit 0
      fi
      sleep 5
    done
    echo 'TIMEOUT: All group not found'
    exit 1
  " || {
  log "API provisioning logs (api-provision sidecar):"
  kubectl -n "$NAMESPACE" logs deployment/"$RELEASE"-server -c api-provision 2>/dev/null || true
  fail "API provisioning did not complete within timeout — All group not found"
}
log "API provisioning complete"

# ── Peer join test: create setup key → join peer → verify ────────────
log "Testing peer registration flow..."

# Step 1: Create a non-"All" group, then create a setup key with it.
# NetBird forbids adding the "All" group to setup keys, so we create a
# dedicated "e2e-peers" group and use that for auto_groups.  Peers are
# automatically added to the "All" group by AddPeerToAllGroup() anyway.
kubectl -n "$NAMESPACE" run peer-join-test --image=alpine:3.20 --restart=Never \
  --env="PAT_TOKEN=$PAT_TOKEN" \
  --env="SVC_URL=$SVC_URL" \
  --command -- sh -c '
    apk add --no-cache curl jq >/dev/null 2>&1
    sleep 3

    # Verify the All group exists (proves the seed worked)
    echo "==> Verifying All group exists..."
    GROUPS=$(curl -s \
      -H "Authorization: Token $PAT_TOKEN" \
      "$SVC_URL/api/groups")
    ALL_GROUP_ID=$(echo "$GROUPS" | jq -r ".[] | select(.name==\"All\") | .id")
    if [ -z "$ALL_GROUP_ID" ]; then
      echo "FAIL: Could not find All group"
      echo "Groups response: $GROUPS"
      exit 1
    fi
    echo "All group ID: $ALL_GROUP_ID"

    # Create a dedicated group for the setup key
    echo "==> Creating e2e-peers group..."
    GRP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Token $PAT_TOKEN" \
      -H "Content-Type: application/json" \
      "$SVC_URL/api/groups" \
      -d "{\"name\":\"e2e-peers\"}")
    GRP_HTTP=$(echo "$GRP_RESPONSE" | tail -1)
    GRP_BODY=$(echo "$GRP_RESPONSE" | sed "\$d")
    echo "Create group HTTP status: $GRP_HTTP"
    E2E_GROUP_ID=$(echo "$GRP_BODY" | jq -r ".id")
    if [ -z "$E2E_GROUP_ID" ] || [ "$E2E_GROUP_ID" = "null" ]; then
      echo "FAIL: Could not create e2e-peers group"
      echo "Response: $GRP_BODY"
      exit 1
    fi
    echo "e2e-peers group ID: $E2E_GROUP_ID"

    # Create a reusable setup key using the e2e-peers group
    echo "==> Creating setup key..."
    SK_BODY=$(jq -n \
      --arg gid "$E2E_GROUP_ID" \
      "{name:\"e2e-test-key\",type:\"reusable\",expires_in:86400,auto_groups:[\$gid],usage_limit:0}")
    echo "Request body: $SK_BODY"
    SK_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Token $PAT_TOKEN" \
      -H "Content-Type: application/json" \
      "$SVC_URL/api/setup-keys" \
      -d "$SK_BODY")
    SK_HTTP_CODE=$(echo "$SK_RESPONSE" | tail -1)
    SK_BODY_RESP=$(echo "$SK_RESPONSE" | sed "\$d")
    echo "HTTP status: $SK_HTTP_CODE"
    echo "Response: $(echo "$SK_BODY_RESP" | head -c 300)"
    SETUP_KEY=$(echo "$SK_BODY_RESP" | jq -r ".key")
    if [ -z "$SETUP_KEY" ] || [ "$SETUP_KEY" = "null" ]; then
      echo "FAIL: Could not create setup key"
      exit 1
    fi
    echo "Setup key created: $(echo $SETUP_KEY | cut -c1-8)..."
    # Output in a machine-parseable format for extraction
    echo "SETUP_KEY=$SETUP_KEY"
    echo "PASS: Setup key created successfully"
  '

log "Waiting for peer-join-test pod..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/peer-join-test --timeout=60s 2>/dev/null || true
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/peer-join-test --timeout=60s || {
  log "peer-join-test pod logs:"
  kubectl -n "$NAMESPACE" logs peer-join-test || true
  fail "Setup key creation failed"
}
log "peer-join-test pod logs:"
kubectl -n "$NAMESPACE" logs peer-join-test || true

# Step 2: Extract the setup key from the pod logs.
# The pod writes "SETUP_KEY=<value>" so we can parse it reliably.
SETUP_KEY=$(kubectl -n "$NAMESPACE" logs peer-join-test | sed -n 's/^SETUP_KEY=//p')
if [ -z "$SETUP_KEY" ]; then
  fail "Could not extract setup key from peer-join-test logs"
fi
log "Using setup key: ${SETUP_KEY:0:8}..."

# Step 3: Run two NetBird client pods that register using the setup key.
# The official netbird image uses an entrypoint script that starts the
# daemon service and then runs "netbird up". We pass the setup key and
# management URL via environment variables that the entrypoint reads.
MGMT_URL="http://$RELEASE-server.$NAMESPACE.svc.cluster.local:80"
log "Starting two NetBird peer pods..."
for PEER_INDEX in 1 2; do
cat <<PEER_EOF | kubectl -n "$NAMESPACE" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: netbird-peer-${PEER_INDEX}
spec:
  restartPolicy: Never
  containers:
    - name: netbird-peer
      image: netbirdio/netbird:latest
      env:
        - name: NB_SETUP_KEY
          value: "$SETUP_KEY"
        - name: NB_MANAGEMENT_URL
          value: "$MGMT_URL"
        - name: NB_LOG_FILE
          value: "console"
        - name: NB_HOSTNAME
          value: "e2e-test-peer-${PEER_INDEX}"
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW", "BPF"]
PEER_EOF
done

log "Waiting for peer pods to start (up to 90s)..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/netbird-peer-1 --timeout=90s 2>/dev/null || true
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/netbird-peer-2 --timeout=90s 2>/dev/null || true

# Give peers time to register and sync network maps
sleep 30

log "NetBird peer-1 logs (last 40 lines):"
kubectl -n "$NAMESPACE" logs netbird-peer-1 2>/dev/null | tail -40 || true
log "NetBird peer-2 logs (last 40 lines):"
kubectl -n "$NAMESPACE" logs netbird-peer-2 2>/dev/null | tail -40 || true

# Step 4: Verify both peers are registered and can see each other
log "Verifying peer registration and network map sync..."
kubectl -n "$NAMESPACE" run peer-verify --image=alpine:3.20 --restart=Never \
  --env="PAT_TOKEN=$PAT_TOKEN" \
  --env="SVC_URL=$SVC_URL" \
  --command -- sh -c '
    apk add --no-cache curl jq >/dev/null 2>&1
    sleep 3
    echo "==> Checking /api/peers..."
    PEERS=$(curl -s \
      -H "Authorization: Token $PAT_TOKEN" \
      "$SVC_URL/api/peers")
    echo "Peers response: $(echo "$PEERS" | jq "." | head -c 2000)"
    PEER_COUNT=$(echo "$PEERS" | jq "length")
    echo "Peer count: $PEER_COUNT"
    if [ "$PEER_COUNT" -lt 2 ]; then
      echo "FAIL: Expected at least 2 peers, got $PEER_COUNT"
      exit 1
    fi
    echo "PASS: Found $PEER_COUNT registered peers"

    # Verify both peers are in the All group and can see each other.
    # NOTE: The /api/peers list endpoint hardcodes accessible_peers_count=0
    # (see peers_handler.go in NetBird source). The real count is only
    # available via /api/peers/{id}/accessible-peers, so we use that.
    echo "==> Checking group membership and accessible peers..."
    FAILED=0
    for i in $(seq 0 $((PEER_COUNT - 1))); do
      PEER_ID=$(echo "$PEERS" | jq -r ".[$i].id")
      HOSTNAME=$(echo "$PEERS" | jq -r ".[$i].hostname // .[$i].name // \"peer-$i\"")
      IN_ALL=$(echo "$PEERS" | jq -r ".[$i].groups[] | select(.name==\"All\") | .name")
      CONNECTED=$(echo "$PEERS" | jq -r ".[$i].connected")

      # Fetch the real accessible peers count via the per-peer endpoint
      AP=$(curl -s \
        -H "Authorization: Token $PAT_TOKEN" \
        "$SVC_URL/api/peers/$PEER_ID/accessible-peers")
      ACCESSIBLE=$(echo "$AP" | jq "length")

      echo "Peer $HOSTNAME: in_all_group=$([ -n "$IN_ALL" ] && echo yes || echo no) accessible_peers=$ACCESSIBLE connected=$CONNECTED"
      if [ -z "$IN_ALL" ]; then
        echo "FAIL: Peer $HOSTNAME is not in the All group"
        FAILED=1
      fi
      if [ "$ACCESSIBLE" -lt 1 ] 2>/dev/null; then
        echo "FAIL: Peer $HOSTNAME has $ACCESSIBLE accessible peers (expected > 0)"
        FAILED=1
      fi
    done
    if [ "$FAILED" -eq 1 ]; then
      echo "FAIL: Not all peers passed verification"
      exit 1
    fi
    echo "PASS: All peers are in the All group with accessible peers > 0"
  '

log "Waiting for peer-verify pod..."
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/peer-verify --timeout=60s 2>/dev/null || true
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/peer-verify --timeout=120s || {
  log "peer-verify pod logs:"
  kubectl -n "$NAMESPACE" logs peer-verify || true
  log "netbird-peer-1 logs (last 50 lines):"
  kubectl -n "$NAMESPACE" logs netbird-peer-1 2>/dev/null | tail -50 || true
  log "netbird-peer-2 logs (last 50 lines):"
  kubectl -n "$NAMESPACE" logs netbird-peer-2 2>/dev/null | tail -50 || true
  fail "Peer verification failed"
}
log "peer-verify pod logs:"
kubectl -n "$NAMESPACE" logs peer-verify || true

log "E2E test with $BACKEND backend PASSED (including PAT seeding, peer registration, and network map sync)!"
