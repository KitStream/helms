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
{{- end }}

{{/*
netbird.database.seedSpec — renders the Initium seed spec YAML for
creating the target database if it doesn't exist.
Only rendered for non-sqlite database types.

The spec is a MiniJinja template — {{ env.DB_PASSWORD }} is resolved
by Initium at runtime from the DB_PASSWORD environment variable.
*/}}
{{- define "netbird.database.seedSpec" -}}
database:
  driver: {{ include "netbird.database.engine" . }}
{{- if eq .Values.database.type "postgresql" }}
  url: "postgres://{{ .Values.database.user }}:{{ "{{ env.DB_PASSWORD }}" }}@{{ .Values.database.host }}:{{ include "netbird.database.port" . }}/?sslmode={{ .Values.database.sslMode }}"
{{- else if eq .Values.database.type "mysql" }}
  url: "mysql://{{ .Values.database.user }}:{{ "{{ env.DB_PASSWORD }}" }}@{{ .Values.database.host }}:{{ include "netbird.database.port" . }}/{{ .Values.database.name }}"
{{- end }}
phases:
  - name: create-database
    database: {{ .Values.database.name }}
    create_if_missing: true
{{- end }}
{{/*
netbird.database.patDatabaseUrl — constructs the database URL for PAT seeding.
This URL connects to the target database (not the system database).
For sqlite, it points to the database file.
The spec is a MiniJinja template — {{ env.DB_PASSWORD }} is resolved
by Initium at runtime from the DB_PASSWORD environment variable.
*/}}
{{- define "netbird.database.patDatabaseUrl" -}}
{{- if eq .Values.database.type "sqlite" -}}
/var/lib/netbird/store.db
{{- else if eq .Values.database.type "postgresql" -}}
postgres://{{ .Values.database.user }}:{{ "{{ env.DB_PASSWORD }}" }}@{{ .Values.database.host }}:{{ include "netbird.database.port" . }}/{{ .Values.database.name }}?sslmode={{ .Values.database.sslMode }}
{{- else if eq .Values.database.type "mysql" -}}
mysql://{{ .Values.database.user }}:{{ "{{ env.DB_PASSWORD }}" }}@{{ .Values.database.host }}:{{ include "netbird.database.port" . }}/{{ .Values.database.name }}
{{- end -}}
{{- end }}
{{/*
netbird.pat.seedSpec — renders the Initium seed spec YAML for
inserting a Personal Access Token into the database.
The seed waits for the personal_access_tokens table (created by NetBird
on startup via GORM AutoMigrate), then idempotently inserts the
account, user, and PAT records.
MiniJinja placeholders:
  {{ env.PAT_HASHED_TOKEN }} — base64-encoded SHA256 hash of the PAT
*/}}
{{- define "netbird.pat.seedSpec" -}}
database:
  driver: {{ include "netbird.database.engine" . }}
  url: "{{ include "netbird.database.patDatabaseUrl" . }}"
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
        order: 1
        tables:
          - table: accounts
            unique_key: [id]
            rows:
              - id: {{ .Values.pat.accountId | quote }}
                created_by: "helm-seed"
                domain: "netbird.selfhosted"
                domain_category: "private"
                is_domain_primary_account: 1
                network_identifier: "seed-network"
                network_net: "100.64.0.0/10"
                network_dns: ""
                network_serial: 0
      - name: pat-user
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
                issued: "api"
      - name: pat-token
        order: 3
        tables:
          - table: personal_access_tokens
            unique_key: [id]
            rows:
              - id: "helm-seeded-pat"
                user_id: {{ .Values.pat.userId | quote }}
                name: {{ .Values.pat.name | quote }}
                hashed_token: "{{ "{{ env.PAT_HASHED_TOKEN }}" }}"
                expiration_date: {{ now | dateModify (printf "+%dh" (mul .Values.pat.expirationDays 24)) | date "2006-01-02 15:04:05" | quote }}
                created_by: {{ .Values.pat.userId | quote }}
                created_at: {{ now | date "2006-01-02 15:04:05" | quote }}
{{- end }}
