{{/*
Expand the name of the chart.
*/}}
{{- define "keycloak.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "keycloak.fullname" -}}
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
{{- define "keycloak.chart" -}}
  {{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "keycloak.labels" -}}
helm.sh/chart: {{ include "keycloak.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "keycloak.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keycloak.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
All labels (common + selector)
*/}}
{{- define "keycloak.allLabels" -}}
{{ include "keycloak.labels" . }}
{{ include "keycloak.selectorLabels" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "keycloak.serviceAccountName" -}}
  {{- if .Values.serviceAccount.create }}
{{- default (include "keycloak.fullname" .) .Values.serviceAccount.name }}
  {{- else }}
{{- default "default" .Values.serviceAccount.name }}
  {{- end }}
{{- end }}

{{/*
Headless service FQDN for dns-ping JGroups discovery
*/}}
{{- define "keycloak.headlessServiceFQDN" -}}
  {{- printf "%s-headless.%s.svc.cluster.local" (include "keycloak.fullname" .) .Release.Namespace }}
{{- end }}

{{/* ===== Database helpers ===== */}}

{{/*
keycloak.database.isExternal — true when database.type is not dev.
*/}}
{{- define "keycloak.database.isExternal" -}}
{{- ne .Values.database.type "dev" -}}
{{- end }}

{{/*
keycloak.database.vendor — maps database.type to KC_DB value.
*/}}
{{- define "keycloak.database.vendor" -}}
  {{- if eq .Values.database.type "postgresql" -}}postgres
  {{- else if eq .Values.database.type "mysql" -}}mysql
  {{- else if eq .Values.database.type "mssql" -}}mssql
  {{- else -}}dev-file
  {{- end -}}
{{- end }}

{{/*
keycloak.database.port — resolves the effective database port.
*/}}
{{- define "keycloak.database.port" -}}
  {{- if .Values.database.port -}}
{{- .Values.database.port -}}
  {{- else if eq .Values.database.type "postgresql" -}}5432
  {{- else if eq .Values.database.type "mysql" -}}3306
  {{- else if eq .Values.database.type "mssql" -}}1433
  {{- else -}}0
  {{- end -}}
{{- end }}

{{/*
keycloak.envConfigData — renders the ConfigMap data block for KC_* environment
variables. Used both in the ConfigMap template and as a checksum source for
rolling deployment updates.
*/}}
{{- define "keycloak.envConfigData" -}}
KC_HEALTH_ENABLED: {{ .Values.healthEnabled | quote }}
KC_METRICS_ENABLED: {{ .Values.metrics.enabled | quote }}
KC_LOG_LEVEL: {{ .Values.logLevel | quote }}
KC_HTTP_ENABLED: {{ .Values.httpEnabled | quote }}
{{- if .Values.hostname }}
KC_HOSTNAME: {{ .Values.hostname | quote }}
{{- end }}
KC_HOSTNAME_STRICT: {{ .Values.hostnameStrict | quote }}
{{- if .Values.hostnameAdmin }}
KC_HOSTNAME_ADMIN: {{ .Values.hostnameAdmin | quote }}
{{- end }}
{{- if .Values.proxyHeaders }}
KC_PROXY_HEADERS: {{ .Values.proxyHeaders | quote }}
{{- end }}
{{- if .Values.features }}
KC_FEATURES: {{ .Values.features | quote }}
{{- end }}
{{- if .Values.tls.enabled }}
KC_HTTPS_CERTIFICATE_FILE: "/opt/keycloak/conf/tls/tls.crt"
KC_HTTPS_CERTIFICATE_KEY_FILE: "/opt/keycloak/conf/tls/tls.key"
{{- end }}
{{- if eq (include "keycloak.database.isExternal" .) "true" }}
KC_DB: {{ include "keycloak.database.vendor" . | quote }}
KC_DB_URL_HOST: {{ .Values.database.host | quote }}
KC_DB_URL_PORT: {{ include "keycloak.database.port" . | quote }}
KC_DB_URL_DATABASE: {{ .Values.database.name | quote }}
KC_DB_USERNAME: {{ .Values.database.user | quote }}
  {{- if .Values.database.poolMinSize }}
KC_DB_POOL_MIN_SIZE: {{ .Values.database.poolMinSize | quote }}
  {{- end }}
  {{- if .Values.database.poolInitialSize }}
KC_DB_POOL_INITIAL_SIZE: {{ .Values.database.poolInitialSize | quote }}
  {{- end }}
  {{- if .Values.database.poolMaxSize }}
KC_DB_POOL_MAX_SIZE: {{ .Values.database.poolMaxSize | quote }}
  {{- end }}
  {{- if .Values.database.sslMode }}
    {{- if eq .Values.database.type "postgresql" }}
KC_DB_URL_PROPERTIES: {{ printf "?sslmode=%s" .Values.database.sslMode | quote }}
    {{- end }}
  {{- end }}
{{- end }}
{{- if eq .Values.database.type "dev" }}
KC_CACHE: "local"
{{- else }}
KC_CACHE: "ispn"
KC_CACHE_STACK: {{ .Values.cache.stack | quote }}
{{- if eq .Values.cache.stack "kubernetes" }}
KC_CACHE_CONFIG_FILE: "cache-ispn.xml"
JAVA_OPTS_APPEND: {{ printf "-Djgroups.dns.query=%s" (include "keycloak.headlessServiceFQDN" .) | quote }}
{{- end }}
{{- end }}
{{- end }}
