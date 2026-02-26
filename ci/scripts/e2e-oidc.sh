#!/usr/bin/env bash
#
# E2E test runner for the netbird Helm chart — OIDC integration.
#
# Usage:
#   ci/scripts/e2e-oidc.sh <provider>
#
# Providers:
#   keycloak — Keycloak deployed in-cluster (quay.io/keycloak/keycloak:26.0)
#   zitadel  — Zitadel + PostgreSQL deployed in-cluster (ghcr.io/zitadel/zitadel:v2.71.6)
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

# ── Deploy Zitadel + PostgreSQL ─────────────────────────────────────
# Architecture: PostgreSQL → Zitadel (init containers: init + setup,
# main container: start, Alpine sidecar for PAT reading).
# The Zitadel image is distroless — it has no shell, no cat — so a
# sidecar is needed to read files from the shared /tmp volume.
ZITADEL_DB_ENVS='
            - name: ZITADEL_DATABASE_POSTGRES_HOST
              value: "zitadel-db"
            - name: ZITADEL_DATABASE_POSTGRES_PORT
              value: "5432"
            - name: ZITADEL_DATABASE_POSTGRES_DATABASE
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE
              value: "disable"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE
              value: "disable"'

deploy_zitadel() {
  log "Deploying PostgreSQL for Zitadel..."
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: zitadel-db
spec:
  selector:
    app: zitadel-db
  ports:
    - port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zitadel-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zitadel-db
  template:
    metadata:
      labels:
        app: zitadel-db
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_DB
              value: "zitadel"
            - name: POSTGRES_USER
              value: "zitadel"
            - name: POSTGRES_PASSWORD
              value: "zitadel-test-pw"
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "zitadel"]
            initialDelaySeconds: 5
            periodSeconds: 3
            failureThreshold: 10
EOF

  log "Waiting for PostgreSQL to be ready..."
  kubectl -n "$NAMESPACE" rollout status deployment/zitadel-db --timeout=120s

  log "Deploying Zitadel (init → setup → start)..."
  kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: zitadel
spec:
  selector:
    app: zitadel
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zitadel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zitadel
  template:
    metadata:
      labels:
        app: zitadel
    spec:
      # Disable Kubernetes service link env vars to prevent ZITADEL_PORT
      # being set to "tcp://10.x.x.x:8080" (Zitadel reads ZITADEL_PORT
      # as its config Port field and fails to parse it as a uint).
      enableServiceLinks: false
      initContainers:
        # Phase 1: init — creates database schema (idempotent)
        - name: zitadel-init
          image: ghcr.io/zitadel/zitadel:v2.71.6
          command: ["/app/zitadel"]
          args: ["init"]
          env:
            - name: ZITADEL_DATABASE_POSTGRES_HOST
              value: "zitadel-db"
            - name: ZITADEL_DATABASE_POSTGRES_PORT
              value: "5432"
            - name: ZITADEL_DATABASE_POSTGRES_DATABASE
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE
              value: "disable"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE
              value: "disable"
        # Phase 2: setup — runs migrations, creates default instance + machine user + PAT
        - name: zitadel-setup
          image: ghcr.io/zitadel/zitadel:v2.71.6
          command: ["/app/zitadel"]
          args:
            - setup
            - --masterkey
            - "x123456789012345678901234567891y"
            - --tlsMode
            - disabled
          env:
            - name: ZITADEL_EXTERNALDOMAIN
              value: "zitadel.netbird-e2e.svc.cluster.local"
            - name: ZITADEL_EXTERNALPORT
              value: "8080"
            - name: ZITADEL_EXTERNALSECURE
              value: "false"
            - name: ZITADEL_DATABASE_POSTGRES_HOST
              value: "zitadel-db"
            - name: ZITADEL_DATABASE_POSTGRES_PORT
              value: "5432"
            - name: ZITADEL_DATABASE_POSTGRES_DATABASE
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE
              value: "disable"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE
              value: "disable"
            - name: ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME
              value: "zitadel-admin@zitadel.localhost"
            - name: ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD
              value: "Password1!"
            - name: ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME
              value: "bootstrap-sa"
            - name: ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME
              value: "Bootstrap Service Account"
            - name: ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINEKEY_TYPE
              value: "1"
            - name: ZITADEL_FIRSTINSTANCE_ORG_MACHINE_PAT_EXPIRATIONDATE
              value: "2030-01-01T00:00:00Z"
            - name: ZITADEL_FIRSTINSTANCE_PATPATH
              value: "/tmp/zitadel-pat"
          volumeMounts:
            - name: zitadel-tmp
              mountPath: /tmp
      containers:
        # Main container: Zitadel server
        - name: zitadel
          image: ghcr.io/zitadel/zitadel:v2.71.6
          command: ["/app/zitadel"]
          args:
            - start
            - --masterkey
            - "x123456789012345678901234567891y"
            - --tlsMode
            - disabled
          env:
            - name: ZITADEL_EXTERNALDOMAIN
              value: "zitadel.netbird-e2e.svc.cluster.local"
            - name: ZITADEL_EXTERNALPORT
              value: "8080"
            - name: ZITADEL_EXTERNALSECURE
              value: "false"
            - name: ZITADEL_DATABASE_POSTGRES_HOST
              value: "zitadel-db"
            - name: ZITADEL_DATABASE_POSTGRES_PORT
              value: "5432"
            - name: ZITADEL_DATABASE_POSTGRES_DATABASE
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE
              value: "disable"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME
              value: "zitadel"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
              value: "zitadel-test-pw"
            - name: ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE
              value: "disable"
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /debug/ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 20
          volumeMounts:
            - name: zitadel-tmp
              mountPath: /tmp
        # Sidecar: Alpine shell for reading PAT from shared /tmp
        # (Zitadel image is distroless — no shell, no cat)
        - name: pat-reader
          image: alpine:3.20
          command: ["sh", "-c", "while true; do sleep 3600; done"]
          volumeMounts:
            - name: zitadel-tmp
              mountPath: /tmp
      volumes:
        - name: zitadel-tmp
          emptyDir: {}
EOF

  log "Waiting for Zitadel to be ready (this may take 1-2 minutes)..."
  kubectl -n "$NAMESPACE" rollout status deployment/zitadel --timeout=600s
}

# ── Configure Zitadel project, apps, and users via REST API ────────
# Outputs: writes a resolved values file to $ZITADEL_VALUES_FILE
configure_zitadel() {
  log "Configuring Zitadel project and clients..."

  # Read the bootstrap PAT from the sidecar container
  ZITADEL_POD=$(kubectl -n "$NAMESPACE" get pod -l app=zitadel -o jsonpath='{.items[0].metadata.name}')
  log "Reading bootstrap PAT from pod $ZITADEL_POD (pat-reader sidecar)..."
  BOOTSTRAP_PAT=""
  for attempt in $(seq 1 30); do
    BOOTSTRAP_PAT=$(kubectl -n "$NAMESPACE" exec "$ZITADEL_POD" -c pat-reader -- cat /tmp/zitadel-pat 2>/dev/null || true)
    if [ -n "$BOOTSTRAP_PAT" ]; then
      break
    fi
    sleep 2
  done
  if [ -z "$BOOTSTRAP_PAT" ]; then
    fail "Could not read bootstrap PAT from Zitadel pod"
  fi
  log "Got bootstrap PAT"

  # Run setup from a pod inside the cluster (for DNS resolution)
  kubectl -n "$NAMESPACE" run zitadel-setup --image=alpine:3.20 --restart=Never \
    --env="BOOTSTRAP_PAT=$BOOTSTRAP_PAT" \
    --command -- sh -c '
    apk add --no-cache curl jq >/dev/null 2>&1

    ZT_URL="http://zitadel.netbird-e2e.svc.cluster.local:8080"
    PAT="$BOOTSTRAP_PAT"
    AUTH="Authorization: Bearer $PAT"

    # Wait for Zitadel API
    echo "Waiting for Zitadel API..."
    for i in $(seq 1 60); do
      if curl -sf "$ZT_URL/debug/ready" >/dev/null 2>&1; then
        echo "Zitadel API is ready"
        break
      fi
      if [ "$i" -eq 60 ]; then
        echo "FAIL: Zitadel not ready after 60 attempts"
        exit 1
      fi
      sleep 3
    done

    # Grant the bootstrap SA IAM_ORG_MANAGER role so it can create users
    echo "Granting bootstrap SA org owner role..."
    # Get the bootstrap SA user ID
    BOOTSTRAP_USER=$(curl -sS "$ZT_URL/management/v1/users/me" \
      -H "$AUTH" -H "Content-Type: application/json" | jq -r ".user.id")
    echo "Bootstrap user ID: $BOOTSTRAP_USER"

    # 1. Create project
    echo "Creating NETBIRD project..."
    PROJECT_RESP=$(curl -sS -X POST "$ZT_URL/management/v1/projects" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"name\":\"NETBIRD\",\"projectRoleAssertion\":true}")
    PROJECT_ID=$(echo "$PROJECT_RESP" | jq -r ".id")
    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
      echo "FAIL: Could not create project"
      echo "$PROJECT_RESP"
      exit 1
    fi
    echo "Project ID: $PROJECT_ID"

    # 2. Create Dashboard OIDC app (public, user-agent type)
    echo "Creating Dashboard OIDC app..."
    DASH_RESP=$(curl -sS -X POST "$ZT_URL/management/v1/projects/$PROJECT_ID/apps/oidc" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{
        \"name\":\"Dashboard\",
        \"redirectUris\":[\"https://netbird.localhost/nb-auth\",\"https://netbird.localhost/nb-silent-auth\"],
        \"postLogoutRedirectUris\":[\"https://netbird.localhost/\"],
        \"responseTypes\":[\"OIDC_RESPONSE_TYPE_CODE\"],
        \"grantTypes\":[\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\",\"OIDC_GRANT_TYPE_REFRESH_TOKEN\"],
        \"appType\":\"OIDC_APP_TYPE_USER_AGENT\",
        \"authMethodType\":\"OIDC_AUTH_METHOD_TYPE_NONE\",
        \"devMode\":true,
        \"accessTokenType\":\"OIDC_TOKEN_TYPE_JWT\",
        \"accessTokenRoleAssertion\":true,
        \"idTokenRoleAssertion\":true,
        \"idTokenUserinfoAssertion\":true
      }")
    DASHBOARD_CLIENT_ID=$(echo "$DASH_RESP" | jq -r ".clientId")
    if [ -z "$DASHBOARD_CLIENT_ID" ] || [ "$DASHBOARD_CLIENT_ID" = "null" ]; then
      echo "FAIL: Could not create Dashboard app"
      echo "$DASH_RESP"
      exit 1
    fi
    echo "Dashboard client ID: $DASHBOARD_CLIENT_ID"

    # 3. Create CLI OIDC app (native, device code grant)
    echo "Creating CLI OIDC app..."
    CLI_RESP=$(curl -sS -X POST "$ZT_URL/management/v1/projects/$PROJECT_ID/apps/oidc" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{
        \"name\":\"CLI\",
        \"redirectUris\":[\"http://localhost:53000/\",\"http://localhost:54000/\"],
        \"postLogoutRedirectUris\":[\"http://localhost:53000/\"],
        \"responseTypes\":[\"OIDC_RESPONSE_TYPE_CODE\"],
        \"grantTypes\":[\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\",\"OIDC_GRANT_TYPE_DEVICE_CODE\",\"OIDC_GRANT_TYPE_REFRESH_TOKEN\"],
        \"appType\":\"OIDC_APP_TYPE_NATIVE\",
        \"authMethodType\":\"OIDC_AUTH_METHOD_TYPE_NONE\",
        \"devMode\":true,
        \"accessTokenType\":\"OIDC_TOKEN_TYPE_JWT\",
        \"accessTokenRoleAssertion\":true,
        \"idTokenRoleAssertion\":true,
        \"idTokenUserinfoAssertion\":true
      }")
    CLI_CLIENT_ID=$(echo "$CLI_RESP" | jq -r ".clientId")
    if [ -z "$CLI_CLIENT_ID" ] || [ "$CLI_CLIENT_ID" = "null" ]; then
      echo "FAIL: Could not create CLI app"
      echo "$CLI_RESP"
      exit 1
    fi
    echo "CLI client ID: $CLI_CLIENT_ID"

    # 4. Create a service user for IdP management
    echo "Creating service user for IdP management..."
    SVC_RESP=$(curl -sS -X POST "$ZT_URL/management/v1/users/machine" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{
        \"userName\":\"netbird-service-account\",
        \"name\":\"NetBird Service Account\",
        \"description\":\"NetBird IdP manager service account\",
        \"accessTokenType\":\"ACCESS_TOKEN_TYPE_JWT\"
      }")
    SVC_USER_ID=$(echo "$SVC_RESP" | jq -r ".userId")
    if [ -z "$SVC_USER_ID" ] || [ "$SVC_USER_ID" = "null" ]; then
      echo "FAIL: Could not create service user"
      echo "$SVC_RESP"
      exit 1
    fi
    echo "Service user ID: $SVC_USER_ID"

    # Generate client secret for the service user
    echo "Generating client secret for service user..."
    SECRET_RESP=$(curl -sS -X PUT "$ZT_URL/management/v1/users/$SVC_USER_ID/secret" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{}")
    SVC_CLIENT_ID=$(echo "$SECRET_RESP" | jq -r ".clientId")
    SVC_CLIENT_SECRET=$(echo "$SECRET_RESP" | jq -r ".clientSecret")
    if [ -z "$SVC_CLIENT_ID" ] || [ "$SVC_CLIENT_ID" = "null" ]; then
      echo "FAIL: Could not generate client secret"
      echo "$SECRET_RESP"
      exit 1
    fi
    echo "Service user client ID: $SVC_CLIENT_ID"

    # Grant Org User Manager role to the service user
    echo "Granting ORG_USER_MANAGER role to service user..."
    curl -sS -X POST "$ZT_URL/management/v1/orgs/me/members" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"userId\":\"$SVC_USER_ID\",\"roles\":[\"ORG_USER_MANAGER\"]}" >/dev/null

    # 5. Create test human user
    echo "Creating test human user..."
    curl -sS -X POST "$ZT_URL/v2/users/human" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{
        \"username\":\"testuser\",
        \"profile\":{\"givenName\":\"Test\",\"familyName\":\"User\",\"displayName\":\"Test User\"},
        \"email\":{\"email\":\"test@netbird.test\",\"isVerified\":true},
        \"password\":{\"password\":\"TestPassword1!\",\"changeRequired\":false}
      }" >/dev/null

    # Output results as a simple key=value format for the caller to parse
    echo ""
    echo "ZITADEL_SETUP_RESULTS_START"
    echo "PROJECT_ID=$PROJECT_ID"
    echo "DASHBOARD_CLIENT_ID=$DASHBOARD_CLIENT_ID"
    echo "CLI_CLIENT_ID=$CLI_CLIENT_ID"
    echo "SVC_CLIENT_ID=$SVC_CLIENT_ID"
    echo "SVC_CLIENT_SECRET=$SVC_CLIENT_SECRET"
    echo "ZITADEL_SETUP_RESULTS_END"

    echo ""
    echo "Zitadel configuration complete"
    exit 0
  '

  log "Waiting for Zitadel setup pod..."
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod/zitadel-setup --timeout=60s 2>/dev/null || true
  kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/zitadel-setup --timeout=180s || {
    log "Zitadel setup pod logs:"
    kubectl -n "$NAMESPACE" logs zitadel-setup || true
    fail "Zitadel configuration failed"
  }
  log "Zitadel setup pod logs:"
  SETUP_LOGS=$(kubectl -n "$NAMESPACE" logs zitadel-setup)
  echo "$SETUP_LOGS"

  # Parse the setup results
  PROJECT_ID=$(echo "$SETUP_LOGS" | sed -n 's/^PROJECT_ID=//p')
  DASHBOARD_CLIENT_ID=$(echo "$SETUP_LOGS" | sed -n 's/^DASHBOARD_CLIENT_ID=//p')
  CLI_CLIENT_ID=$(echo "$SETUP_LOGS" | sed -n 's/^CLI_CLIENT_ID=//p')
  SVC_CLIENT_ID=$(echo "$SETUP_LOGS" | sed -n 's/^SVC_CLIENT_ID=//p')
  SVC_CLIENT_SECRET=$(echo "$SETUP_LOGS" | sed -n 's/^SVC_CLIENT_SECRET=//p')

  if [ -z "$PROJECT_ID" ] || [ -z "$DASHBOARD_CLIENT_ID" ] || [ -z "$CLI_CLIENT_ID" ] || [ -z "$SVC_CLIENT_ID" ] || [ -z "$SVC_CLIENT_SECRET" ]; then
    fail "Could not parse Zitadel setup results"
  fi

  log "Zitadel setup results:"
  log "  Project ID:          $PROJECT_ID"
  log "  Dashboard client ID: $DASHBOARD_CLIENT_ID"
  log "  CLI client ID:       $CLI_CLIENT_ID"
  log "  Service client ID:   $SVC_CLIENT_ID"

  kubectl -n "$NAMESPACE" delete pod zitadel-setup --ignore-not-found 2>/dev/null || true

  # Create the K8s secret for IdP manager client credentials
  log "Creating Zitadel IdP secret..."
  kubectl -n "$NAMESPACE" create secret generic netbird-zitadel-idp-secret \
    --from-literal=clientSecret="$SVC_CLIENT_SECRET"

  # Generate the resolved values file by substituting placeholders
  ZITADEL_VALUES_FILE=$(mktemp)
  sed \
    -e "s/PLACEHOLDER_PROJECT_ID/$PROJECT_ID/g" \
    -e "s/PLACEHOLDER_DASHBOARD_CLIENT_ID/$DASHBOARD_CLIENT_ID/g" \
    -e "s/PLACEHOLDER_CLI_CLIENT_ID/$CLI_CLIENT_ID/g" \
    -e "s/PLACEHOLDER_SVC_CLIENT_ID/$SVC_CLIENT_ID/g" \
    "$CHART/ci/e2e-values-oidc-zitadel.yaml" > "$ZITADEL_VALUES_FILE"

  log "Resolved values written to $ZITADEL_VALUES_FILE"
}

# ── Provider dispatch ────────────────────────────────────────────────
case "$PROVIDER" in
  keycloak)
    deploy_keycloak
    configure_keycloak
    create_oidc_secrets
    VALUES_FILE="$CHART/ci/e2e-values-oidc-keycloak.yaml"
    ;;
  zitadel)
    deploy_zitadel
    configure_zitadel
    VALUES_FILE="$ZITADEL_VALUES_FILE"
    ;;
  *)
    fail "Unknown OIDC provider: $PROVIDER (expected: keycloak, zitadel)"
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
#   2. Token acquisition works against the IdP (realm/project configured)
# Full token-based auth testing is out of scope for the chart e2e:
# NetBird's embedded IdP layer re-signs tokens internally.
log "Verifying OIDC middleware is active..."
SVC_URL="http://$RELEASE-server.$NAMESPACE.svc.cluster.local:80"

# Write the test script into a ConfigMap to avoid escaping issues
OIDC_TEST_SCRIPT=$(mktemp)
cat > "$OIDC_TEST_SCRIPT" <<'TESTEOF'
#!/bin/sh
set -e
apk add --no-cache curl jq >/dev/null 2>&1
sleep 3

echo "==> Test 1: Unauthenticated request should return 401..."
HTTP_CODE=$(curl -s -o /tmp/body -w '%{http_code}' "$SVC_URL/api/groups")
echo "HTTP status: $HTTP_CODE"
echo "Body: $(cat /tmp/body | head -c 200)"
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: Expected HTTP 401, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Unauthenticated request returned 401 (OIDC middleware active)"

echo ""
if [ "$PROVIDER" = "keycloak" ]; then
  echo "==> Test 2: Obtain access token via Keycloak direct grant..."
  TOKEN_RESPONSE=$(curl -sf -X POST \
    "$IDP_URL/realms/netbird/protocol/openid-connect/token" \
    -d "client_id=netbird-client" \
    -d "username=testuser" \
    -d "password=testpassword" \
    -d "grant_type=password" \
    -d "scope=openid profile email")
  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "FAIL: Could not obtain access token from Keycloak"
    echo "Token response: $(echo "$TOKEN_RESPONSE" | head -c 500)"
    exit 1
  fi
  echo "PASS: Keycloak token acquisition succeeded"

elif [ "$PROVIDER" = "zitadel" ]; then
  echo "==> Test 2: Verify Zitadel OIDC discovery endpoint..."
  OIDC_CONFIG=$(curl -sf "$IDP_URL/.well-known/openid-configuration")
  TOKEN_EP=$(echo "$OIDC_CONFIG" | jq -r '.token_endpoint')
  if [ -z "$TOKEN_EP" ] || [ "$TOKEN_EP" = "null" ]; then
    echo "FAIL: Could not discover token_endpoint from Zitadel OIDC config"
    echo "OIDC config: $(echo "$OIDC_CONFIG" | head -c 500)"
    exit 1
  fi
  echo "PASS: Zitadel OIDC discovery returned token_endpoint: $TOKEN_EP"

  echo ""
  echo "==> Test 3: Obtain client_credentials token from Zitadel..."
  TOKEN_RESPONSE=$(curl -sf -X POST "$IDP_URL/oauth/v2/token" \
    -u "$SVC_CLIENT_ID:$SVC_CLIENT_SECRET" \
    -d "grant_type=client_credentials" \
    -d "scope=openid profile urn:zitadel:iam:org:project:id:zitadel:aud")
  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "FAIL: Could not obtain client_credentials token from Zitadel"
    echo "Token response: $(echo "$TOKEN_RESPONSE" | head -c 500)"
    exit 1
  fi
  echo "PASS: Zitadel client_credentials token acquisition succeeded"
fi

echo ""
echo "All OIDC e2e checks passed"
exit 0
TESTEOF

# Create ConfigMap from the test script
kubectl -n "$NAMESPACE" create configmap oidc-test-script \
  --from-file=test.sh="$OIDC_TEST_SCRIPT"
rm -f "$OIDC_TEST_SCRIPT"

# Determine IdP URL and extra env vars per provider
case "$PROVIDER" in
  keycloak) IDP_URL="http://keycloak.$NAMESPACE.svc.cluster.local:8080" ;;
  zitadel)  IDP_URL="http://zitadel.$NAMESPACE.svc.cluster.local:8080" ;;
esac

kubectl -n "$NAMESPACE" apply -f - <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: oidc-test
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: alpine:3.20
      command: ["sh", "/scripts/test.sh"]
      env:
        - name: PROVIDER
          value: "$PROVIDER"
        - name: SVC_URL
          value: "$SVC_URL"
        - name: IDP_URL
          value: "$IDP_URL"
        - name: SVC_CLIENT_ID
          value: "${SVC_CLIENT_ID:-}"
        - name: SVC_CLIENT_SECRET
          value: "${SVC_CLIENT_SECRET:-}"
      volumeMounts:
        - name: scripts
          mountPath: /scripts
  volumes:
    - name: scripts
      configMap:
        name: oidc-test-script
PODEOF

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
