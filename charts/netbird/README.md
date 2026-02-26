# NetBird Helm Chart

A Helm chart for deploying [NetBird](https://netbird.io) VPN management, signal, dashboard, and relay services on Kubernetes.

## Overview

This chart deploys the NetBird self-hosted stack as two components:

| Component | Description |
|-----------|-------------|
| **Server** | Combined binary running Management API, Signal, Relay, and STUN services on a single HTTP port |
| **Dashboard** | Web UI for managing peers, groups, routes, and access policies |

The server uses a single `config.yaml` that is rendered from a ConfigMap template with sensitive values injected at pod startup from Kubernetes Secrets via [Initium](https://github.com/KitStream/initium)'s `render` subcommand (envsubst mode).

For external databases (PostgreSQL, MySQL), the chart automatically:
1. **Waits** for the database to be reachable (`initium wait-for`)
2. **Creates** the database if it doesn't exist (`initium seed --spec`)
3. **Constructs** the DSN internally from structured `database.*` values — you never need to build a DSN string

## Prerequisites

- Kubernetes 1.24+ (1.28+ required for SQLite PAT seeding with native sidecars)
- Helm 3.x
- An OAuth2 / OIDC identity provider (Auth0, Keycloak, Authentik, Zitadel, etc.)
- An Ingress controller (nginx recommended) with TLS termination

## Installation

```bash
helm install netbird ./charts/netbird \
  -n netbird --create-namespace \
  -f my-values.yaml
```

## Minimal Configuration Example

### SQLite (default)

```yaml
server:
  config:
    exposedAddress: "https://netbird.example.com"
    auth:
      issuer: "https://auth.example.com"
      dashboardRedirectURIs:
        - "https://netbird.example.com/nb-auth"
        - "https://netbird.example.com/nb-silent-auth"
```

### PostgreSQL

```yaml
database:
  type: postgresql
  host: postgres.database.svc.cluster.local
  port: 5432
  user: netbird
  name: netbird
  passwordSecret:
    secretName: netbird-db-password
    secretKey: password

server:
  config:
    exposedAddress: "https://netbird.example.com"
    auth:
      issuer: "https://auth.example.com"
      dashboardRedirectURIs:
        - "https://netbird.example.com/nb-auth"
        - "https://netbird.example.com/nb-silent-auth"
```

### MySQL

```yaml
database:
  type: mysql
  host: mysql.database.svc.cluster.local
  port: 3306
  user: netbird
  name: netbird
  passwordSecret:
    secretName: netbird-db-password
    secretKey: password

server:
  config:
    exposedAddress: "https://netbird.example.com"
    auth:
      issuer: "https://auth.example.com"
      dashboardRedirectURIs:
        - "https://netbird.example.com/nb-auth"
        - "https://netbird.example.com/nb-silent-auth"
```

The chart automatically constructs the DSN and adds init containers to wait for the database and create it if needed.

For all configurations, add ingress settings:

```yaml
server:
  ingress:
    enabled: true
    hosts:
      - host: netbird.example.com
        paths:
          - path: /api
            pathType: ImplementationSpecific
          - path: /oauth2
            pathType: ImplementationSpecific
    tls:
      - secretName: netbird-tls
        hosts:
          - netbird.example.com
  ingressGrpc:
    enabled: true
    hosts:
      - host: netbird.example.com
        paths:
          - path: /signalexchange.SignalExchange
            pathType: ImplementationSpecific
          - path: /management.ManagementService
            pathType: ImplementationSpecific
    tls:
      - secretName: netbird-tls
        hosts:
          - netbird.example.com
  ingressRelay:
    enabled: true
    hosts:
      - host: netbird.example.com
        paths:
          - path: /relay
            pathType: ImplementationSpecific
          - path: /ws-proxy
            pathType: ImplementationSpecific
    tls:
      - secretName: netbird-tls
        hosts:
          - netbird.example.com

dashboard:
  config:
    mgmtApiEndpoint: "https://netbird.example.com"
    mgmtGrpcApiEndpoint: "https://netbird.example.com"
    authAuthority: "https://auth.example.com"
    authClientId: "netbird-dashboard"
    authAudience: "netbird-dashboard"
  ingress:
    enabled: true
    hosts:
      - host: netbird.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: netbird-tls
        hosts:
          - netbird.example.com
```

## Personal Access Token (PAT) Seeding

The chart can optionally seed the database with a Personal Access Token
after deployment. This enables immediate API access without manual token
creation — useful for automation, CI/CD, and GitOps workflows.

### Generating a PAT

NetBird PATs have the format `nbp_<30-char-secret><6-char-checksum>` (40
chars total). The SHA256 hash required by the database is computed
automatically by the seed process (Initium v1.0.4+) — you only need to
generate the plaintext token.

```bash
# Using Python
python3 -c "
import secrets, zlib
secret = secrets.token_urlsafe(22)[:30]
checksum = zlib.crc32(secret.encode()) & 0xffffffff
chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
cs = ''
v = checksum
while v > 0: cs = chars[v % 62] + cs; v //= 62
token = 'nbp_' + secret + cs.rjust(6, '0')
print(f'Token: {token}')
"

# Or using openssl (simplified checksum)
TOKEN="nbp_$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c30)000000"
echo "Token: $TOKEN"
```

### Creating the Secret

```bash
kubectl create secret generic netbird-pat \
  --from-literal=token='nbp_...' \
  -n netbird
```

### Enabling PAT Seeding

```yaml
pat:
  enabled: true
  secret:
    secretName: netbird-pat
  name: "my-api-token"
  expirationDays: 365
```

The seeding mechanism depends on the database type:

- **SQLite**: The seed runs as a **native sidecar** (Kubernetes 1.28+) in the
  server Deployment. It is declared as an init container with
  `restartPolicy: Always` and uses the `--sidecar` flag to stay alive after
  seeding. This is required because SQLite uses a local file and
  ReadWriteOnce PVCs cannot be mounted by multiple pods simultaneously.
- **PostgreSQL / MySQL**: The seed runs as a post-install/post-upgrade Helm
  hook Job that connects to the database over the network.

In both cases, the seed:
1. Waits for the `accounts`, `users`, and `personal_access_tokens` tables
   to exist (created by the server via GORM AutoMigrate)
2. Idempotently inserts a service user account and PAT

> **Note:** The SQLite PAT sidecar requires **Kubernetes 1.28+** for native
> sidecar support. The sidecar stays alive after completing the seed
> (via Initium's `--sidecar` flag), so the pod shows `2/2 Running`.

### Using the PAT

```bash
# Authenticate with the PAT
curl -H "Authorization: Token nbp_..." https://netbird.example.com/api/groups
```

## Values Reference

### Global

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `nameOverride` | string | `""` | Override the chart name in resource names |
| `fullnameOverride` | string | `""` | Fully override the resource name prefix |
| `imagePullSecrets` | list | `[]` | Global image pull secrets for all pods |
| `serviceAccount.create` | bool | `true` | Create a ServiceAccount |
| `serviceAccount.annotations` | object | `{}` | ServiceAccount annotations |
| `serviceAccount.name` | string | `""` | ServiceAccount name override |

### Database

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `database.type` | string | `"sqlite"` | Database engine (`sqlite`, `postgresql`, `mysql`) |
| `database.host` | string | `""` | Database hostname (required for postgresql/mysql) |
| `database.port` | string | `""` | Database port (defaults: 5432 for postgresql, 3306 for mysql) |
| `database.user` | string | `""` | Database user (required for postgresql/mysql) |
| `database.name` | string | `""` | Database name (required for postgresql/mysql) |
| `database.passwordSecret.secretName` | string | `""` | Secret containing the database password |
| `database.passwordSecret.secretKey` | string | `"password"` | Key in the Secret |
| `database.sslMode` | string | `"disable"` | SSL mode for PostgreSQL (ignored for mysql/sqlite) |

### PAT (Personal Access Token)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `pat.enabled` | bool | `false` | Enable PAT seeding via post-install Job |
| `pat.secret.secretName` | string | `""` | Kubernetes Secret containing the plaintext PAT |
| `pat.secret.tokenKey` | string | `"token"` | Key in Secret for the plaintext PAT |
| `pat.name` | string | `"helm-seeded-token"` | Display name for the PAT |
| `pat.userId` | string | `"helm-seed-user"` | User ID for the service user |
| `pat.accountId` | string | `"helm-seed-account"` | Account ID for the service user |
| `pat.expirationDays` | int | `365` | PAT expiration in days from deployment |

### Server

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.replicaCount` | int | `1` | Number of server pod replicas |
| `server.image.repository` | string | `"netbirdio/netbird-server"` | Server image repository |
| `server.image.tag` | string | `""` (appVersion) | Server image tag |
| `server.image.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `server.initImage.repository` | string | `"ghcr.io/kitstream/initium"` | Init container image ([Initium](https://github.com/KitStream/initium)) |
| `server.initImage.tag` | string | `"1.0.4"` | Init container image tag |
| `server.imagePullSecrets` | list | `[]` | Component-level pull secrets |

#### Server Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.config.listenAddress` | string | `":80"` | Address and port the server listens on |
| `server.config.exposedAddress` | string | `""` | Public URL for peer connections |
| `server.config.stunPorts` | list | `[3478]` | UDP ports for the embedded STUN server |
| `server.config.metricsPort` | int | `9090` | Prometheus metrics port |
| `server.config.healthcheckAddress` | string | `":9000"` | Health check endpoint address |
| `server.config.logLevel` | string | `"info"` | Log verbosity (debug, info, warn, error) |
| `server.config.logFile` | string | `"console"` | Log output destination |
| `server.config.dataDir` | string | `"/var/lib/netbird"` | Data directory for state and DB |
| `server.config.auth.issuer` | string | `""` | OAuth2/OIDC issuer URL |
| `server.config.auth.signKeyRefreshEnabled` | bool | `true` | Auto-refresh IdP signing keys |
| `server.config.auth.dashboardRedirectURIs` | list | `[]` | Dashboard OAuth2 redirect URIs |
| `server.config.auth.cliRedirectURIs` | list | `["http://localhost:53000/"]` | CLI redirect URIs |

#### Server Secrets

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.secrets.authSecret.secretName` | string | `""` | Existing Secret name (empty = auto-generate) |
| `server.secrets.authSecret.secretKey` | string | `"authSecret"` | Key in the Secret |
| `server.secrets.authSecret.autoGenerate` | bool | `true` | Auto-generate on first install |
| `server.secrets.storeEncryptionKey.secretName` | string | `""` | Existing Secret name (empty = auto-generate) |
| `server.secrets.storeEncryptionKey.secretKey` | string | `"encryptionKey"` | Key in the Secret |
| `server.secrets.storeEncryptionKey.autoGenerate` | bool | `true` | Auto-generate on first install |

#### Server Storage

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.persistentVolume.enabled` | bool | `true` | Create a PVC for server data |
| `server.persistentVolume.storageClass` | string | `""` | Storage class (empty = cluster default) |
| `server.persistentVolume.accessModes` | list | `["ReadWriteOnce"]` | PVC access modes |
| `server.persistentVolume.size` | string | `"1Gi"` | PVC size |
| `server.persistentVolume.annotations` | object | `{}` | PVC annotations |

#### Server Networking

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.stunPort` | int | `3478` | STUN UDP container port |
| `server.service.type` | string | `"ClusterIP"` | Server service type |
| `server.service.port` | int | `80` | Server service port |
| `server.stunService.type` | string | `"LoadBalancer"` | STUN service type |
| `server.stunService.port` | int | `3478` | STUN service port |
| `server.stunService.annotations` | object | `{}` | STUN service annotations |

#### Server Ingress

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.ingress.enabled` | bool | `false` | Create HTTP ingress (API + OAuth2) |
| `server.ingress.className` | string | `"nginx"` | Ingress class |
| `server.ingress.annotations` | object | `{}` | Ingress annotations |
| `server.ingress.hosts` | list | `[]` | Ingress host rules |
| `server.ingress.tls` | list | `[]` | TLS configuration |
| `server.ingressGrpc.enabled` | bool | `false` | Create gRPC ingress (Signal + Management) |
| `server.ingressGrpc.className` | string | `"nginx"` | Ingress class |
| `server.ingressGrpc.annotations` | object | see values.yaml | GRPC backend annotations |
| `server.ingressGrpc.hosts` | list | `[]` | Ingress host rules |
| `server.ingressGrpc.tls` | list | `[]` | TLS configuration |
| `server.ingressRelay.enabled` | bool | `false` | Create relay/WebSocket ingress |
| `server.ingressRelay.className` | string | `"nginx"` | Ingress class |
| `server.ingressRelay.annotations` | object | `{}` | Ingress annotations |
| `server.ingressRelay.hosts` | list | `[]` | Ingress host rules |
| `server.ingressRelay.tls` | list | `[]` | TLS configuration |

#### Server Pod

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `server.resources` | object | `{}` | CPU/memory requests and limits |
| `server.nodeSelector` | object | `{}` | Node selector labels |
| `server.tolerations` | list | `[]` | Pod tolerations |
| `server.affinity` | object | `{}` | Pod affinity rules |
| `server.podAnnotations` | object | `{}` | Pod annotations |
| `server.podLabels` | object | `{}` | Additional pod labels |
| `server.podSecurityContext` | object | `{}` | Pod security context |
| `server.securityContext` | object | `{}` | Container security context |
| `server.livenessProbe` | object | TCP check on `http` port | Liveness probe |
| `server.readinessProbe` | object | TCP check on `http` port | Readiness probe |

### Dashboard

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `dashboard.replicaCount` | int | `1` | Number of dashboard replicas |
| `dashboard.image.repository` | string | `"netbirdio/dashboard"` | Dashboard image |
| `dashboard.image.tag` | string | `"v2.32.4"` | Dashboard image tag |
| `dashboard.image.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `dashboard.imagePullSecrets` | list | `[]` | Component-level pull secrets |

#### Dashboard Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `dashboard.config.mgmtApiEndpoint` | string | `""` | Management API URL |
| `dashboard.config.mgmtGrpcApiEndpoint` | string | `""` | Management gRPC URL |
| `dashboard.config.authAudience` | string | `"netbird-dashboard"` | OAuth2 audience |
| `dashboard.config.authClientId` | string | `"netbird-dashboard"` | OAuth2 client ID |
| `dashboard.config.authAuthority` | string | `""` | OAuth2 authority / issuer URL |
| `dashboard.config.useAuth0` | string | `"false"` | Use Auth0 as IdP |
| `dashboard.config.authSupportedScopes` | string | `"openid profile email groups"` | OAuth2 scopes |
| `dashboard.config.authRedirectUri` | string | `"/nb-auth"` | Auth redirect path |
| `dashboard.config.authSilentRedirectUri` | string | `"/nb-silent-auth"` | Silent auth redirect path |
| `dashboard.config.nginxSslPort` | string | `"443"` | NGINX SSL port inside the container |
| `dashboard.config.letsencryptDomain` | string | `"none"` | Let's Encrypt domain ("none" = external TLS) |

#### Dashboard Secrets

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `dashboard.secrets.authClientSecret.value` | string | `""` | Plain-text client secret (when no Secret ref) |
| `dashboard.secrets.authClientSecret.secretName` | string | `""` | Existing Secret name |
| `dashboard.secrets.authClientSecret.secretKey` | string | `"clientSecret"` | Key in the Secret |

#### Dashboard Extra

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `dashboard.extraEnv` | list | `[]` | Additional environment variables |

#### Dashboard Networking

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `dashboard.service.type` | string | `"ClusterIP"` | Dashboard service type |
| `dashboard.service.port` | int | `80` | Dashboard service port |
| `dashboard.ingress.enabled` | bool | `false` | Create dashboard ingress |
| `dashboard.ingress.className` | string | `"nginx"` | Ingress class |
| `dashboard.ingress.annotations` | object | `{}` | Ingress annotations |
| `dashboard.ingress.hosts` | list | `[]` | Ingress host rules |
| `dashboard.ingress.tls` | list | `[]` | TLS configuration |

#### Dashboard Pod

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `dashboard.resources` | object | `{}` | CPU/memory requests and limits |
| `dashboard.nodeSelector` | object | `{}` | Node selector labels |
| `dashboard.tolerations` | list | `[]` | Pod tolerations |
| `dashboard.affinity` | object | `{}` | Pod affinity rules |
| `dashboard.podAnnotations` | object | `{}` | Pod annotations |
| `dashboard.podLabels` | object | `{}` | Additional pod labels |
| `dashboard.podSecurityContext` | object | `{}` | Pod security context |
| `dashboard.securityContext` | object | `{}` | Container security context |
| `dashboard.livenessProbe` | object | HTTP GET `/` | Liveness probe |
| `dashboard.readinessProbe` | object | HTTP GET `/` | Readiness probe |

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     Ingress Controller                   │
│                                                          │
│  /api, /oauth2 ──────────┐                               │
│  /signalexchange/*, /management/* ──► Server Pod :80     │
│  /relay, /ws-proxy ──────┘       (Management + Signal    │
│                                   + Relay combined)      │
│  / ──────────────────────────────► Dashboard Pod :80     │
└──────────────────────────────────────────────────────────┘
                                        │
                               STUN Service :3478/UDP
                               (LoadBalancer)
```

## Upstream Source

This chart is based on the [NetBird](https://github.com/netbirdio/netbird) project. See the `sources` field in `Chart.yaml` for details.

## License

Apache License 2.0 — see [LICENSE](../../LICENSE).

