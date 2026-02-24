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
netbird.escapeEnvsubst — escapes a string so that envsubst will not
interpret any ${...} or $VAR references inside user-supplied values.
All "$" characters are replaced with the literal string "${DOLLAR}"
and the init container pre-defines DOLLAR='$' before running envsubst.
*/}}
{{- define "netbird.escapeEnvsubst" -}}
{{- . | replace "$" "${DOLLAR}" }}
{{- end }}

{{/*
netbird.server.generatedSecretName — name of the Secret this chart creates
when auto-generating secrets (authSecret, storeEncryptionKey).
*/}}
{{- define "netbird.server.generatedSecretName" -}}
{{- printf "%s-generated" (include "netbird.server.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
netbird.server.resolveSecretName — resolves the effective secret name for a
given secret ref. If the user supplied a secretName, use it. Otherwise, if
autoGenerate is true, use the chart-generated secret name. Otherwise return "".
Usage: include "netbird.server.resolveSecretName" (dict "ref" .Values.server.secrets.authSecret "generated" (include "netbird.server.generatedSecretName" .))
*/}}
{{- define "netbird.server.resolveSecretName" -}}
{{- if .ref.secretName -}}
{{- .ref.secretName -}}
{{- else if .ref.autoGenerate -}}
{{- .generated -}}
{{- end -}}
{{- end }}

{{/*
netbird.server.configTemplate — renders the config.yaml template with
envsubst-style placeholders for sensitive values that the init container
will substitute at runtime using GNU envsubst.

Placeholders (envsubst variables):
  ${AUTH_SECRET}       <- server.secrets.authSecret
  ${ENCRYPTION_KEY}    <- server.secrets.storeEncryptionKey
  ${STORE_DSN}         <- server.secrets.storeDsn (only for postgres/mysql)

All user-supplied values are escaped via the netbird.escapeEnvsubst helper
so that any "$" in user input is rendered literally and not interpreted by
envsubst.

The generated structure matches the official NetBird config.yaml format:
  https://docs.netbird.io/selfhosted/configuration-files
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
    engine: {{ include "netbird.escapeEnvsubst" .Values.server.config.store.engine | quote }}
    dsn: {{ if ne .Values.server.config.store.engine "sqlite" }}"${STORE_DSN}"{{ else }}""{{ end }}
    encryptionKey: "${ENCRYPTION_KEY}"
{{- end }}
