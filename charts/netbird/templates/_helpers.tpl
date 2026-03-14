{{/*
Expand the name of the chart.
*/}}
{{- define "netbird.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "netbird.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label
*/}}
{{- define "netbird.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "netbird.labels" -}}
helm.sh/chart: {{ include "netbird.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* ===== Server (combined) ===== */}}

{{- define "netbird.server.fullname" -}}
{{- printf "%s-server" (include "netbird.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "netbird.server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{- define "netbird.server.labels" -}}
{{ include "netbird.labels" . }}
{{ include "netbird.server.selectorLabels" . }}
{{- end }}

{{/* ===== Dashboard ===== */}}

{{- define "netbird.dashboard.fullname" -}}
{{- printf "%s-dashboard" (include "netbird.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "netbird.dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: dashboard
{{- end }}

{{- define "netbird.dashboard.labels" -}}
{{ include "netbird.labels" . }}
{{ include "netbird.dashboard.selectorLabels" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "netbird.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "netbird.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
envFromSecret helper — renders valueFrom.secretKeyRef entries
from a map of ENV_VAR: "secretName/secretKey"
*/}}
{{- define "netbird.envFromSecret" -}}
{{- range $envName, $ref := . }}
{{- $parts := splitList "/" $ref }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ index $parts 0 }}
      key: {{ index $parts 1 }}
{{- end }}
{{- end }}

{{/*
netbird.escapeEnvsubst — escapes "$" to "${DOLLAR}" so Initium's
render subcommand (envsubst mode) won't interpret user values.
*/}}
{{- define "netbird.escapeEnvsubst" -}}
{{- . | replace "$" "${DOLLAR}" }}
{{- end }}

{{/*
netbird.server.generatedSecretName — name of the auto-generated Secret.
*/}}
{{- define "netbird.server.generatedSecretName" -}}
{{- printf "%s-generated" (include "netbird.server.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
netbird.server.resolveSecretName — resolves the effective secret name.
*/}}
{{- define "netbird.server.resolveSecretName" -}}
{{- if .ref.secretName -}}
{{- .ref.secretName -}}
{{- else if .ref.autoGenerate -}}
{{- .generated -}}
{{- end -}}
{{- end }}

{{/* ===== Database helpers ===== */}}

{{/*
netbird.database.engine — maps database.type to the NetBird store engine name.
  postgresql -> postgres, mysql -> mysql, sqlite -> sqlite
*/}}
{{- define "netbird.database.engine" -}}
{{- if eq .Values.database.type "postgresql" -}}postgres
{{- else -}}{{ .Values.database.type }}
{{- end -}}
{{- end }}

{{/*
netbird.database.port — resolves the effective database port.
Defaults to 5432 for postgresql, 3306 for mysql.
*/}}
{{- define "netbird.database.port" -}}
{{- if .Values.database.port -}}
{{- .Values.database.port -}}
{{- else if eq .Values.database.type "postgresql" -}}5432
{{- else if eq .Values.database.type "mysql" -}}3306
{{- else -}}0
{{- end -}}
{{- end }}

{{/*
netbird.database.isExternal — true when database.type is not sqlite.
*/}}
{{- define "netbird.database.isExternal" -}}
{{- ne .Values.database.type "sqlite" -}}
{{- end }}

{{/* ===== OIDC helpers ===== */}}

{{/*
netbird.oidc.providerCredentialsKey — maps idpManager.managerType to the
corresponding YAML key for provider-specific credentials in config.yaml.
  auth0    -> auth0ClientCredentials
  azure    -> azureClientCredentials
  keycloak -> keycloakClientCredentials
  zitadel  -> zitadelClientCredentials
  (other)  -> <type>ClientCredentials
*/}}
{{- define "netbird.oidc.providerCredentialsKey" -}}
{{- if eq . "auth0" -}}auth0ClientCredentials
{{- else if eq . "azure" -}}azureClientCredentials
{{- else if eq . "keycloak" -}}keycloakClientCredentials
{{- else if eq . "zitadel" -}}zitadelClientCredentials
{{- else -}}{{ . }}ClientCredentials
{{- end -}}
{{- end }}

{{/*
netbird.database.dsn — constructs the DSN string with ${DB_PASSWORD} placeholder.
  postgresql: host=H user=U password=${DB_PASSWORD} dbname=D port=P sslmode=S
  mysql:      U:${DB_PASSWORD}@tcp(H:P)/D
  sqlite:     (empty string)
*/}}
{{- define "netbird.database.dsn" -}}
{{- if eq .Values.database.type "postgresql" -}}
host={{ .Values.database.host }} user={{ .Values.database.user }} password=${DB_PASSWORD} dbname={{ .Values.database.name }} port={{ include "netbird.database.port" . }} sslmode={{ .Values.database.sslMode }}
{{- else if eq .Values.database.type "mysql" -}}
{{ .Values.database.user }}:${DB_PASSWORD}@tcp({{ .Values.database.host }}:{{ include "netbird.database.port" . }})/{{ .Values.database.name }}
{{- end -}}
{{- end }}

{{/*
netbird.server.configTemplate — renders the config.yaml template with
envsubst-style placeholders. Initium's render subcommand substitutes
these at pod startup.

Placeholders:
  ${AUTH_SECRET}       <- server.secrets.authSecret
  ${ENCRYPTION_KEY}    <- server.secrets.storeEncryptionKey
  ${DB_PASSWORD}       <- database.passwordSecret (embedded in DSN, non-sqlite only)
*/}}
{{- define "netbird.server.configTemplate" -}}
server:
  listenAddress: {{ include "netbird.escapeEnvsubst" .Values.server.config.listenAddress | quote }}
  exposedAddress: {{ include "netbird.escapeEnvsubst" .Values.server.config.exposedAddress | quote }}
  stunPorts:
    {{- toYaml .Values.server.config.stunPorts | nindent 4 }}
  metricsPort: {{ .Values.server.config.metricsPort }}
  healthcheckAddress: {{ include "netbird.escapeEnvsubst" .Values.server.config.healthcheckAddress | quote }}
  logLevel: {{ include "netbird.escapeEnvsubst" .Values.server.config.logLevel | quote }}
  logFile: {{ include "netbird.escapeEnvsubst" .Values.server.config.logFile | quote }}

  authSecret: "${AUTH_SECRET}"
  dataDir: {{ include "netbird.escapeEnvsubst" .Values.server.config.dataDir | quote }}

  auth:
    issuer: {{ include "netbird.escapeEnvsubst" .Values.server.config.auth.issuer | quote }}
    signKeyRefreshEnabled: {{ .Values.server.config.auth.signKeyRefreshEnabled }}
    {{- if .Values.server.config.auth.dashboardRedirectURIs }}
    dashboardRedirectURIs:
      {{- range .Values.server.config.auth.dashboardRedirectURIs }}
      - {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
    {{- end }}
    {{- if .Values.server.config.auth.cliRedirectURIs }}
    cliRedirectURIs:
      {{- range .Values.server.config.auth.cliRedirectURIs }}
      - {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
    {{- end }}

  store:
    engine: {{ include "netbird.database.engine" . | quote }}
    dsn: {{ if eq (include "netbird.database.isExternal" .) "true" }}"{{ include "netbird.database.dsn" . }}"{{ else }}""{{ end }}
    encryptionKey: "${ENCRYPTION_KEY}"
{{- if .Values.oidc.enabled }}

  http:
    authAudience: {{ include "netbird.escapeEnvsubst" .Values.oidc.audience | quote }}
    {{- with .Values.oidc.userIdClaim }}
    authUserIDClaim: {{ include "netbird.escapeEnvsubst" . | quote }}
    {{- end }}
    {{- with .Values.oidc.configEndpoint }}
    oidcConfigEndpoint: {{ include "netbird.escapeEnvsubst" . | quote }}
    {{- end }}
    {{- with .Values.oidc.authKeysLocation }}
    authKeysLocation: {{ include "netbird.escapeEnvsubst" . | quote }}
    {{- end }}
    idpSignKeyRefreshEnabled: {{ .Values.server.config.auth.signKeyRefreshEnabled }}
{{- if .Values.oidc.deviceAuthFlow.enabled }}

  deviceAuthFlow:
    provider: {{ include "netbird.escapeEnvsubst" .Values.oidc.deviceAuthFlow.provider | quote }}
    providerConfig:
      {{- with .Values.oidc.deviceAuthFlow.providerConfig.audience }}
      audience: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      clientId: {{ include "netbird.escapeEnvsubst" .Values.oidc.deviceAuthFlow.providerConfig.clientId | quote }}
      {{- with .Values.oidc.deviceAuthFlow.providerConfig.clientSecret }}
      clientSecret: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      {{- with .Values.oidc.deviceAuthFlow.providerConfig.domain }}
      domain: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      {{- with .Values.oidc.deviceAuthFlow.providerConfig.tokenEndpoint }}
      tokenEndpoint: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      {{- with .Values.oidc.deviceAuthFlow.providerConfig.deviceAuthEndpoint }}
      deviceAuthEndpoint: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      scope: {{ include "netbird.escapeEnvsubst" .Values.oidc.deviceAuthFlow.providerConfig.scope | quote }}
      useIdToken: {{ .Values.oidc.deviceAuthFlow.providerConfig.useIdToken }}
{{- end }}
{{- if .Values.oidc.pkceAuthFlow.enabled }}

  pkceAuthFlow:
    providerConfig:
      {{- with .Values.oidc.pkceAuthFlow.providerConfig.audience }}
      audience: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      clientId: {{ include "netbird.escapeEnvsubst" .Values.oidc.pkceAuthFlow.providerConfig.clientId | quote }}
      {{- if .Values.oidc.pkceAuthFlow.providerConfig.clientSecret.secretName }}
      clientSecret: "${PKCE_CLIENT_SECRET}"
      {{- else }}
      clientSecret: {{ include "netbird.escapeEnvsubst" .Values.oidc.pkceAuthFlow.providerConfig.clientSecret.value | quote }}
      {{- end }}
      {{- with .Values.oidc.pkceAuthFlow.providerConfig.domain }}
      domain: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      {{- with .Values.oidc.pkceAuthFlow.providerConfig.authorizationEndpoint }}
      authorizationEndpoint: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      {{- with .Values.oidc.pkceAuthFlow.providerConfig.tokenEndpoint }}
      tokenEndpoint: {{ include "netbird.escapeEnvsubst" . | quote }}
      {{- end }}
      scope: {{ include "netbird.escapeEnvsubst" .Values.oidc.pkceAuthFlow.providerConfig.scope | quote }}
      {{- with .Values.oidc.pkceAuthFlow.providerConfig.redirectUrls }}
      redirectURLs:
        {{- range . }}
        - {{ include "netbird.escapeEnvsubst" . | quote }}
        {{- end }}
      {{- end }}
      useIdToken: {{ .Values.oidc.pkceAuthFlow.providerConfig.useIdToken }}
      disablePromptLogin: {{ .Values.oidc.pkceAuthFlow.providerConfig.disablePromptLogin }}
      loginFlag: {{ .Values.oidc.pkceAuthFlow.providerConfig.loginFlag }}
{{- end }}
{{- if .Values.oidc.idpManager.enabled }}

  idpConfig:
    managerType: {{ include "netbird.escapeEnvsubst" .Values.oidc.idpManager.managerType | quote }}
    clientConfig:
      issuer: {{ include "netbird.escapeEnvsubst" .Values.oidc.idpManager.clientConfig.issuer | quote }}
      tokenEndpoint: {{ include "netbird.escapeEnvsubst" .Values.oidc.idpManager.clientConfig.tokenEndpoint | quote }}
      clientId: {{ include "netbird.escapeEnvsubst" .Values.oidc.idpManager.clientConfig.clientId | quote }}
      clientSecret: "${IDP_CLIENT_SECRET}"
      grantType: {{ include "netbird.escapeEnvsubst" .Values.oidc.idpManager.clientConfig.grantType | quote }}
    {{- with .Values.oidc.idpManager.extraConfig }}
    extraConfig:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.oidc.idpManager.providerConfig }}
    {{ include "netbird.oidc.providerCredentialsKey" $.Values.oidc.idpManager.managerType }}:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
netbird.database.seedSpec — renders the Initium seed spec YAML for
creating the target database if it doesn't exist.
Only rendered for non-sqlite database types.

Uses Initium v2's structured connection config so that passwords
with special characters work without any URL encoding.
{{ env.DB_PASSWORD }} is resolved by Initium at runtime.
*/}}
{{- define "netbird.database.seedSpec" -}}
database:
  driver: {{ include "netbird.database.engine" . }}
  host: {{ .Values.database.host }}
  port: {{ include "netbird.database.port" . }}
  user: {{ .Values.database.user }}
  password: "{{ "{{ env.DB_PASSWORD }}" }}"
  name: {{ .Values.database.name }}
{{- if eq .Values.database.type "postgresql" }}
  options:
    sslmode: {{ .Values.database.sslMode }}
{{- end }}
phases:
  - name: create-database
    database: {{ .Values.database.name }}
    create_if_missing: true
{{- end }}
{{/*
netbird.pat.seedSpec — renders the Initium seed spec YAML for
inserting a Personal Access Token into the database.
The seed waits for the personal_access_tokens table (created by NetBird
on startup via GORM AutoMigrate), then idempotently inserts the
account, user, PAT, "All" group, default policy, and default policy
rule records.
Seed sets use mode: reconcile so that value changes in the Helm chart
are reflected in the database on upgrade.
MiniJinja placeholders:
  {{ env.PAT_TOKEN | sha256("bytes") | base64_encode }} — computes the
  base64-encoded SHA256 hash from the plaintext PAT at seed time.
*/}}
{{- define "netbird.pat.seedSpec" -}}
database:
  driver: {{ include "netbird.database.engine" . }}
{{- if eq .Values.database.type "sqlite" }}
  url: "/var/lib/netbird/store.db"
{{- else }}
  host: {{ .Values.database.host }}
  port: {{ include "netbird.database.port" . }}
  user: {{ .Values.database.user }}
  password: "{{ "{{ env.DB_PASSWORD }}" }}"
  name: {{ .Values.database.name }}
{{- if eq .Values.database.type "postgresql" }}
  options:
    sslmode: {{ .Values.database.sslMode }}
{{- end }}
{{- end }}
phases:
  - name: seed-pat
    order: 1
    wait_for:
      - type: table
        name: personal_access_tokens
        timeout: 120s
      - type: table
        name: users
        timeout: 120s
      - type: table
        name: accounts
        timeout: 120s
    seed_sets:
      - name: pat-account
        mode: reconcile
        ignore_columns: [network_serial]
        order: 1
        tables:
          - table: accounts
            unique_key: [id]
            rows:
              - id: {{ .Values.pat.accountId | quote }}
                created_by: "helm-seed"
                created_at: {{ now | date "2006-01-02 15:04:05" | quote }}
                domain: "netbird.selfhosted"
                domain_category: "private"
                is_domain_primary_account: 1
                network_net: '{"IP":"100.64.0.0","Mask":"//AAAA=="}'
                network_serial: 0
                dns_settings_disabled_management_groups: "[]"
                settings_peer_login_expiration_enabled: 1
                settings_peer_login_expiration: 86400000000000
                settings_peer_inactivity_expiration_enabled: 0
                settings_peer_inactivity_expiration: 600000000000
                settings_regular_users_view_blocked: 1
                settings_groups_propagation_enabled: 1
                settings_jwt_groups_enabled: 0
                settings_routing_peer_dns_resolution_enabled: 1
                settings_peer_expose_enabled: 0
                settings_extra_peer_approval_enabled: 0
                settings_extra_user_approval_required: 1
      - name: pat-user
        mode: reconcile
        order: 2
        tables:
          - table: users
            unique_key: [id]
            rows:
              - id: {{ .Values.pat.userId | quote }}
                account_id: {{ .Values.pat.accountId | quote }}
                role: "admin"
                is_service_user: 1
                service_user_name: "helm-seed-service-user"
                non_deletable: 0
                blocked: 0
                pending_approval: 0
                issued: "api"
                integration_ref_id: 0
                integration_ref_integration_type: ""
      - name: pat-token
        mode: reconcile
        order: 3
        tables:
          - table: personal_access_tokens
            unique_key: [id]
            rows:
              - id: "helm-seeded-pat"
                user_id: {{ .Values.pat.userId | quote }}
                name: {{ .Values.pat.name | quote }}
                hashed_token: "{{ "{{ env.PAT_TOKEN | sha256(\"bytes\") | base64_encode }}" }}"
                expiration_date: {{ now | dateModify (printf "+%dh" (mul .Values.pat.expirationDays 24)) | date "2006-01-02 15:04:05" | quote }}
                created_by: {{ .Values.pat.userId | quote }}
                created_at: {{ now | date "2006-01-02 15:04:05" | quote }}
{{- end }}
{{/*
netbird.pat.provisionScript — shell script that creates the "All" group
and a default allow-all policy via the NetBird REST API. This runs after
the Initium seed so the PAT is available for authentication.

The script is idempotent: it skips creation if the objects already exist.
*/}}
{{- define "netbird.pat.provisionScript" -}}
#!/bin/sh
set -eu

# Uses only busybox tools (wget, grep, sed) — no apk install needed.
# This allows running as non-root with readOnlyRootFilesystem.

SVC_URL="http://{{ include "netbird.server.fullname" . }}:{{ .Values.server.service.port }}"
AUTH_HEADER="Authorization: Token $PAT_TOKEN"

# Helper: HTTP GET returning body on stdout
api_get() {
  wget -q -O - --header "$AUTH_HEADER" "$SVC_URL$1" 2>/dev/null
}

# Helper: HTTP POST returning body on stdout
api_post() {
  wget -q -O - --header "$AUTH_HEADER" --header "Content-Type: application/json" \
    --post-data "$2" "$SVC_URL$1" 2>/dev/null
}

echo "==> Waiting for NetBird API to accept PAT authentication..."
for i in $(seq 1 60); do
  if api_get "/api/groups" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "FATAL: API did not become ready within timeout"
    exit 1
  fi
  sleep 3
done

echo "==> Checking for existing All group..."
GROUPS=$(api_get "/api/groups")
if echo "$GROUPS" | grep -q '"name":"All"'; then
  # Extract id of the All group using grep/sed
  # JSON is an array of objects; find the one with name "All" and grab its id
  ALL_GROUP_ID=$(echo "$GROUPS" | sed 's/},{/}\n{/g' | grep '"name":"All"' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "All group already exists (id: $ALL_GROUP_ID)"
else
  echo "==> Creating All group via API..."
  ALL_RESP=$(api_post "/api/groups" '{"name":"All"}')
  ALL_GROUP_ID=$(echo "$ALL_RESP" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "Created All group (id: $ALL_GROUP_ID)"
fi

if [ -z "$ALL_GROUP_ID" ]; then
  echo "FATAL: Could not determine All group ID"
  exit 1
fi

echo "==> Checking for existing default policy..."
POLICIES=$(api_get "/api/policies")
if echo "$POLICIES" | grep -q '"name":"Default"'; then
  echo "Default policy already exists — skipping"
else
  echo "==> Creating default allow-all policy via API..."
  POLICY_BODY="{\"name\":\"Default\",\"description\":\"Default policy allowing all connections\",\"enabled\":true,\"rules\":[{\"name\":\"Default\",\"description\":\"Allow all connections\",\"enabled\":true,\"action\":\"accept\",\"bidirectional\":true,\"protocol\":\"all\",\"sources\":[\"$ALL_GROUP_ID\"],\"destinations\":[\"$ALL_GROUP_ID\"]}]}"
  POL_RESP=$(api_post "/api/policies" "$POLICY_BODY")
  if [ -z "$POL_RESP" ]; then
    echo "FATAL: Failed to create default policy"
    exit 1
  fi
  echo "Created default policy"
fi

echo "==> API provisioning complete"
{{- end }}
