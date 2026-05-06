# NetBird Helm Chart

[![CI](https://github.com/KitStream/helms/actions/workflows/ci.yaml/badge.svg)](https://github.com/KitStream/helms/actions/workflows/ci.yaml)
[![Chart Version](https://img.shields.io/badge/chart-0.1.2-blue)](https://github.com/KitStream/helms/releases)
[![App Version](https://img.shields.io/badge/netbird-0.67.1-green)](https://github.com/netbirdio/netbird)

A Helm chart for deploying [NetBird](https://netbird.io) VPN management, signal, dashboard, and relay services on Kubernetes.

## Overview

This chart deploys the NetBird self-hosted stack as two components:

| Component     | Description                                                                                    |
| ------------- | ---------------------------------------------------------------------------------------------- |
| **Server**    | Combined binary running Management API, Signal, Relay, and STUN services on a single HTTP port |
| **Dashboard** | Web UI for managing peers, groups, routes, and access policies                                 |

The server uses a single `config.yaml` that is rendered from a ConfigMap template with sensitive values injected at pod startup from Kubernetes Secrets via [Initium](https://github.com/KitStream/initium)'s `render` subcommand (envsubst mode).

For external databases (PostgreSQL, MySQL), the chart automatically:

1. **Waits** for the database to be reachable (`initium wait-for`)
2. **Creates** the database if it doesn't exist (`initium seed --spec`)
3. **Constructs** the DSN internally from structured `database.*` values — you never need to build a DSN string

## Prerequisites

- Kubernetes 1.24+ (1.28+ required for SQLite PAT seeding with native sidecars)
- Helm 3.x
- An OAuth2 / OIDC identity provider (Auth0, Keycloak, Authentik, Zitadel, etc.) **or** NetBird's built-in embedded IdP
- An Ingress controller (nginx recommended) with TLS termination

## Installation

### From OCI Registry (recommended)

```bash
helm install netbird oci://ghcr.io/kitstream/helms/netbird \
  --version 0.1.1 \
  -n netbird --create-namespace \
  -f my-values.yaml
```

### From Source

```bash
helm install netbird ./charts/netbird \
  -n netbird --create-namespace \
  -f my-values.yaml
```

## Minimal Configuration Example

> **`exposedAddress` must include an explicit port** (e.g. `https://netbird.example.com:443`),
> even when the port matches the scheme default. NetBird clients build their
> gRPC dial target from this URL using Go's `net/url` parser; without an
> explicit port the daemon fails to connect with `missing port in address`.
> The chart enforces this at template time and refuses to install with a
> port-less value.

### Embedded IdP (no external provider)

NetBird includes a built-in identity provider, so an external OAuth2/OIDC
provider is **not required**. To use the embedded IdP, set the issuer to
`https://<your-domain>/oauth2` and configure `managerType: "embedded"`:

```yaml
server:
  config:
    exposedAddress: "https://netbird.example.com:443"
    auth:
      issuer: "https://netbird.example.com/oauth2"
      dashboardRedirectURIs:
        - "https://netbird.example.com/nb-auth"
        - "https://netbird.example.com/nb-silent-auth"

oidc:
  enabled: true
  idpManager:
    enabled: true
    managerType: "embedded"
```

With this setup you manage users through the NetBird dashboard's `/setup`
endpoint — no Keycloak, Auth0, or other external IdP is needed.

### SQLite (default)

```yaml
server:
  config:
    exposedAddress: "https://netbird.example.com:443"
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
    exposedAddress: "https://netbird.example.com:443"
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
    exposedAddress: "https://netbird.example.com:443"
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
  # ⚠ ingressGrpc requires TLS. Standard nginx-ingress cannot negotiate
  # HTTP/2 cleartext (h2c), and the chart sets
  # nginx.ingress.kubernetes.io/ssl-redirect: "true" by default, so
  # plaintext gRPC is redirected to HTTPS and fails without a cert.
  # Enabling this block with an empty `tls:` is rejected at template time.
  # For plaintext h2c, use server.grpcRoute (Gateway API) instead — see the
  # "Gateway API as an alternative to Ingress" section below.
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

## Gateway API as an alternative to Ingress

Each of the Ingress blocks above has a mutually-exclusive Gateway API
counterpart. Use Gateway API when:

- You already terminate TLS at a cluster-wide Gateway and don't want per-app
  `Secret` references.
- You need **plaintext h2c for gRPC**. Standard nginx-ingress cannot
  negotiate HTTP/2 cleartext, so `server.ingressGrpc` requires TLS;
  `server.grpcRoute` does not.
- You prefer Gateway API's richer matching (header/method matches, filters,
  traffic splitting).

The chart renders **routes only** — `HTTPRoute`, `GRPCRoute`, `TCPRoute` —
and attaches them via `parentRefs` to a `Gateway` you already manage. TLS
is configured on that Gateway's listeners, not in these values. Enabling
an Ingress block and its Gateway API counterpart for the same traffic
class fails template rendering with a clear error.

```yaml
server:
  httpRoute:
    enabled: true
    parentRefs:
      - name: my-gateway
        namespace: gateway-system
        sectionName: https
    hostnames:
      - netbird.example.com
    rules:
      - matches:
          - path: { type: PathPrefix, value: /api }
          - path: { type: PathPrefix, value: /oauth2 }
  grpcRoute:
    enabled: true
    parentRefs:
      - name: my-gateway
        namespace: gateway-system
        sectionName: https
    hostnames:
      - netbird.example.com
    rules:
      - matches:
          - method: { service: signalexchange.SignalExchange }
      - matches:
          - method: { service: management.ManagementService }
  relayHttpRoute:
    enabled: true
    parentRefs:
      - name: my-gateway
        namespace: gateway-system
        sectionName: https
    hostnames:
      - netbird.example.com
    rules:
      - matches:
          - path: { type: PathPrefix, value: /relay }
          - path: { type: PathPrefix, value: /ws-proxy }

dashboard:
  httpRoute:
    enabled: true
    parentRefs:
      - name: my-gateway
        namespace: gateway-system
        sectionName: https
    hostnames:
      - netbird.example.com
    rules:
      - matches:
          - path: { type: PathPrefix, value: / }
```

Rules that omit `backendRefs` get the netbird server / dashboard `Service`
auto-filled on port 80. Specify `backendRefs` explicitly for traffic
splitting or non-default ports.

For deployments that expose relay as a raw TCP listener (no HTTP path
matching), use `server.relayTcpRoute` — apiVersion
`gateway.networking.k8s.io/v1alpha2`. TCPRoute ships in the Gateway API
**experimental channel**; make sure its CRDs are installed
(`experimental-install.yaml` from the Gateway API release) before
enabling it.

## STUN Networking

NetBird's embedded STUN server uses **UDP port 3478**, which standard HTTP
ingress controllers cannot proxy. The chart therefore creates a dedicated
Kubernetes Service (`server.stunService`) for STUN traffic, separate from
the HTTP ingress.

NetBird clients derive the STUN URI from `server.config.exposedAddress` —
the hostname in `exposedAddress` is combined with port 3478 to form
`stun:<hostname>:3478`. This means the STUN hostname **must resolve to an
IP that reaches the STUN service**.

### Option 1: Separate LoadBalancer (default)

The chart defaults to `server.stunService.type: LoadBalancer`, which
provisions a dedicated external IP for UDP traffic. Because this IP
differs from the ingress controller IP, you need a DNS record that points
to the STUN LoadBalancer:

```
netbird.example.com      → Ingress IP      (HTTP / gRPC / Relay)
stun.netbird.example.com → STUN LB IP      (UDP 3478)
```

Retrieve the STUN external IP after deployment:

```bash
kubectl get svc <release>-server-stun -n <namespace> \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

If you use a separate hostname for STUN you will also need to configure a
custom STUN URI in the NetBird server config so that clients connect to the
correct address.

### Option 2: Shared static IP (single DNS entry)

On cloud providers that support static IP assignment you can give the
**same IP** to both the ingress controller and the STUN LoadBalancer. A
single DNS record then serves both HTTP and UDP traffic:

```yaml
server:
  stunService:
    type: LoadBalancer
    port: 3478
    annotations:
      # GKE example:
      networking.gke.io/load-balancer-ip-refs: "my-static-ip"
      # AWS NLB with Elastic IP:
      service.beta.kubernetes.io/aws-load-balancer-eip-allocations: "eipalloc-xxx"
```

Ensure your ingress controller's external Service also uses the same
static IP so that `exposedAddress` resolves to one address for all
protocols.

### Option 3: NodePort

Expose STUN on a fixed port across all cluster nodes. Useful when a cloud
LoadBalancer is not available or when nodes already have public IPs:

```yaml
server:
  stunService:
    type: NodePort
    port: 3478
```

To pin a specific NodePort instead of letting Kubernetes assign one automatically:

```yaml
server:
  stunService:
    type: NodePort
    port: 3478
    nodePort: 30478
```

Point DNS at one or more node IPs. Clients will connect on the allocated
NodePort (check `kubectl get svc` for the assigned port).

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

## OIDC / SSO Configuration

The chart supports structured OIDC configuration for integrating with
external identity providers. When `oidc.enabled: true`, the chart renders
`http:`, `deviceAuthFlow:`, `pkceAuthFlow:`, and `idpConfig:` sections into
the server config.yaml.

### Keycloak Example

```yaml
server:
  config:
    auth:
      issuer: "https://keycloak.example.com/realms/netbird"

oidc:
  enabled: true
  audience: "netbird"
  userIdClaim: "sub"
  configEndpoint: "https://keycloak.example.com/realms/netbird/.well-known/openid-configuration"

  deviceAuthFlow:
    enabled: true
    provider: "keycloak"
    providerConfig:
      clientId: "netbird-client"
      domain: "keycloak.example.com"
      tokenEndpoint: "https://keycloak.example.com/realms/netbird/protocol/openid-connect/token"
      deviceAuthEndpoint: "https://keycloak.example.com/realms/netbird/protocol/openid-connect/auth/device"
      scope: "openid profile email"

  pkceAuthFlow:
    enabled: true
    providerConfig:
      clientId: "netbird-dashboard"
      authorizationEndpoint: "https://keycloak.example.com/realms/netbird/protocol/openid-connect/auth"
      tokenEndpoint: "https://keycloak.example.com/realms/netbird/protocol/openid-connect/token"
      scope: "openid profile email groups offline_access"
      redirectUrls:
        - "https://netbird.example.com/nb-auth"
        - "https://netbird.example.com/nb-silent-auth"

  idpManager:
    enabled: true
    managerType: "keycloak"
    clientConfig:
      issuer: "https://keycloak.example.com/realms/netbird"
      tokenEndpoint: "https://keycloak.example.com/realms/netbird/protocol/openid-connect/token"
      clientId: "netbird-backend"
      clientSecret:
        secretName: keycloak-client-secret
        secretKey: clientSecret
      grantType: "client_credentials"
```

### Auth0 Example

```yaml
oidc:
  enabled: true
  audience: "netbird-api"
  deviceAuthFlow:
    enabled: true
    provider: "auth0"
    providerConfig:
      clientId: "<spa-client-id>"
      domain: "<tenant>.auth0.com"
      audience: "netbird-api"
  idpManager:
    enabled: true
    managerType: "auth0"
    clientConfig:
      issuer: "https://<tenant>.auth0.com/"
      tokenEndpoint: "https://<tenant>.auth0.com/oauth/token"
      clientId: "<m2m-client-id>"
      clientSecret:
        secretName: auth0-client-secret
        secretKey: clientSecret
      grantType: "client_credentials"
    providerConfig:
      Audience: "https://<tenant>.auth0.com/api/v2/"
      AuthIssuer: "https://<tenant>.auth0.com/"
```

### Azure Entra ID Example

```yaml
oidc:
  enabled: true
  audience: "api://<application-id>"
  userIdClaim: "oid"
  deviceAuthFlow:
    enabled: true
    provider: "azure"
    providerConfig:
      clientId: "<client-id>"
      domain: "login.microsoftonline.com"
      audience: "api://<application-id>"
  idpManager:
    enabled: true
    managerType: "azure"
    clientConfig:
      issuer: "https://login.microsoftonline.com/<tenant-id>/v2.0"
      tokenEndpoint: "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token"
      clientId: "<client-id>"
      clientSecret:
        secretName: azure-client-secret
        secretKey: clientSecret
      grantType: "client_credentials"
    providerConfig:
      ObjectID: "<service-principal-object-id>"
      GraphAPIEndpoint: "https://graph.microsoft.com"
```

### Secret Injection

OIDC client secrets are injected via Kubernetes Secrets and never stored in
ConfigMaps. Create a Secret for your IdP manager client:

```bash
kubectl create secret generic keycloak-client-secret \
  --from-literal=clientSecret='your-client-secret' \
  -n netbird
```

The chart injects the secret as an environment variable (`IDP_CLIENT_SECRET`
or `PKCE_CLIENT_SECRET`) in the config-init container, and references it in
the config template as `${IDP_CLIENT_SECRET}` / `${PKCE_CLIENT_SECRET}`.

### Dashboard Auto-Derivation

When `dashboard.config.authAuthority` is empty, the dashboard automatically
uses `server.config.auth.issuer` as the OIDC authority. You should still set
`dashboard.config.authClientId` and `dashboard.config.authAudience` explicitly.

### Manual Testing for SaaS Providers

Providers that cannot be deployed in-cluster (Azure Entra ID, Auth0, Okta,
ADFS) can be tested manually:

1. Configure the provider with appropriate app registrations
2. Create Kubernetes Secrets with the client credentials
3. Install the chart with provider-specific OIDC values
4. Verify: `kubectl logs` shows the server connecting to the IdP,
   `curl -H "Authorization: Bearer <token>" .../api/users` returns 200

## Values Reference

### Global

| Key                          | Type   | Default | Description                               |
| ---------------------------- | ------ | ------- | ----------------------------------------- |
| `nameOverride`               | string | `""`    | Override the chart name in resource names |
| `fullnameOverride`           | string | `""`    | Fully override the resource name prefix   |
| `imagePullSecrets`           | list   | `[]`    | Global image pull secrets for all pods    |
| `serviceAccount.create`      | bool   | `true`  | Create a ServiceAccount                   |
| `serviceAccount.annotations` | object | `{}`    | ServiceAccount annotations                |
| `serviceAccount.name`        | string | `""`    | ServiceAccount name override              |

### Database

| Key                                  | Type   | Default      | Description                                                   |
| ------------------------------------ | ------ | ------------ | ------------------------------------------------------------- |
| `database.type`                      | string | `"sqlite"`   | Database engine (`sqlite`, `postgresql`, `mysql`)             |
| `database.host`                      | string | `""`         | Database hostname (required for postgresql/mysql)             |
| `database.port`                      | string | `""`         | Database port (defaults: 5432 for postgresql, 3306 for mysql) |
| `database.user`                      | string | `""`         | Database user (required for postgresql/mysql)                 |
| `database.name`                      | string | `""`         | Database name (required for postgresql/mysql)                 |
| `database.passwordSecret.secretName` | string | `""`         | Secret containing the database password                       |
| `database.passwordSecret.secretKey`  | string | `"password"` | Key in the Secret                                             |
| `database.sslMode`                   | string | `"disable"`  | SSL mode for PostgreSQL (ignored for mysql/sqlite)            |

### OIDC / SSO

| Key                                                        | Type   | Default                  | Description                                                |
| ---------------------------------------------------------- | ------ | ------------------------ | ---------------------------------------------------------- |
| `oidc.enabled`                                             | bool   | `false`                  | Enable OIDC configuration                                  |
| `oidc.audience`                                            | string | `""`                     | JWT audience claim (HttpServerConfig.AuthAudience)         |
| `oidc.userIdClaim`                                         | string | `""`                     | JWT user ID claim (default: "sub")                         |
| `oidc.configEndpoint`                                      | string | `""`                     | OIDC discovery endpoint URL                                |
| `oidc.authKeysLocation`                                    | string | `""`                     | JWT keys location URL (JWKS)                               |
| `oidc.deviceAuthFlow.enabled`                              | bool   | `false`                  | Enable device authorization flow (CLI)                     |
| `oidc.deviceAuthFlow.provider`                             | string | `"hosted"`               | Device auth provider name                                  |
| `oidc.deviceAuthFlow.providerConfig.clientId`              | string | `""`                     | Client ID for CLI app                                      |
| `oidc.deviceAuthFlow.providerConfig.clientSecret`          | string | `""`                     | Client secret (usually empty for public)                   |
| `oidc.deviceAuthFlow.providerConfig.domain`                | string | `""`                     | Provider domain                                            |
| `oidc.deviceAuthFlow.providerConfig.audience`              | string | `""`                     | Audience for token validation                              |
| `oidc.deviceAuthFlow.providerConfig.tokenEndpoint`         | string | `""`                     | Token endpoint override                                    |
| `oidc.deviceAuthFlow.providerConfig.deviceAuthEndpoint`    | string | `""`                     | Device auth endpoint override                              |
| `oidc.deviceAuthFlow.providerConfig.scope`                 | string | `"openid"`               | OAuth2 scopes                                              |
| `oidc.deviceAuthFlow.providerConfig.useIdToken`            | bool   | `false`                  | Use ID token instead of access token                       |
| `oidc.pkceAuthFlow.enabled`                                | bool   | `false`                  | Enable PKCE authorization flow (dashboard)                 |
| `oidc.pkceAuthFlow.providerConfig.clientId`                | string | `""`                     | Client ID for dashboard app                                |
| `oidc.pkceAuthFlow.providerConfig.clientSecret.value`      | string | `""`                     | Plain-text client secret                                   |
| `oidc.pkceAuthFlow.providerConfig.clientSecret.secretName` | string | `""`                     | Secret name for client secret                              |
| `oidc.pkceAuthFlow.providerConfig.clientSecret.secretKey`  | string | `"clientSecret"`         | Key in Secret                                              |
| `oidc.pkceAuthFlow.providerConfig.domain`                  | string | `""`                     | Provider domain                                            |
| `oidc.pkceAuthFlow.providerConfig.audience`                | string | `""`                     | Audience                                                   |
| `oidc.pkceAuthFlow.providerConfig.authorizationEndpoint`   | string | `""`                     | Authorization endpoint override                            |
| `oidc.pkceAuthFlow.providerConfig.tokenEndpoint`           | string | `""`                     | Token endpoint override                                    |
| `oidc.pkceAuthFlow.providerConfig.scope`                   | string | `"openid profile email"` | OAuth2 scopes                                              |
| `oidc.pkceAuthFlow.providerConfig.redirectUrls`            | list   | `[]`                     | Allowed redirect URLs                                      |
| `oidc.pkceAuthFlow.providerConfig.useIdToken`              | bool   | `false`                  | Use ID token                                               |
| `oidc.pkceAuthFlow.providerConfig.disablePromptLogin`      | bool   | `false`                  | Disable login prompt                                       |
| `oidc.pkceAuthFlow.providerConfig.loginFlag`               | int    | `0`                      | Login flag value                                           |
| `oidc.idpManager.enabled`                                  | bool   | `false`                  | Enable IdP manager for user sync                           |
| `oidc.idpManager.managerType`                              | string | `""`                     | Manager type (keycloak, auth0, azure, zitadel, okta, etc.) |
| `oidc.idpManager.clientConfig.issuer`                      | string | `""`                     | OIDC issuer for management API                             |
| `oidc.idpManager.clientConfig.tokenEndpoint`               | string | `""`                     | Token endpoint                                             |
| `oidc.idpManager.clientConfig.clientId`                    | string | `""`                     | Client ID                                                  |
| `oidc.idpManager.clientConfig.clientSecret.secretName`     | string | `""`                     | Secret name for client secret                              |
| `oidc.idpManager.clientConfig.clientSecret.secretKey`      | string | `"clientSecret"`         | Key in Secret                                              |
| `oidc.idpManager.clientConfig.grantType`                   | string | `"client_credentials"`   | OAuth2 grant type                                          |
| `oidc.idpManager.extraConfig`                              | object | `{}`                     | Provider-specific extra config                             |
| `oidc.idpManager.providerConfig`                           | object | `{}`                     | Provider-specific credentials                              |

### PAT (Personal Access Token)

| Key                     | Type   | Default               | Description                                    |
| ----------------------- | ------ | --------------------- | ---------------------------------------------- |
| `pat.enabled`           | bool   | `false`               | Enable PAT seeding via post-install Job        |
| `pat.secret.secretName` | string | `""`                  | Kubernetes Secret containing the plaintext PAT |
| `pat.secret.tokenKey`   | string | `"token"`             | Key in Secret for the plaintext PAT            |
| `pat.name`              | string | `"helm-seeded-token"` | Display name for the PAT                       |
| `pat.userId`            | string | `"helm-seed-user"`    | User ID for the service user                   |
| `pat.accountId`         | string | `"helm-seed-account"` | Account ID for the service user                |
| `pat.expirationDays`    | int    | `365`                 | PAT expiration in days from deployment         |

### Server

| Key                           | Type   | Default                       | Description                                                            |
| ----------------------------- | ------ | ----------------------------- | ---------------------------------------------------------------------- |
| `server.replicaCount`         | int    | `1`                           | Number of server pod replicas                                          |
| `server.image.repository`     | string | `"netbirdio/netbird-server"`  | Server image repository                                                |
| `server.image.tag`            | string | `""` (appVersion)             | Server image tag                                                       |
| `server.image.pullPolicy`     | string | `"IfNotPresent"`              | Image pull policy                                                      |
| `server.initImage.repository` | string | `"ghcr.io/kitstream/initium"` | Init container image ([Initium](https://github.com/KitStream/initium)) |
| `server.initImage.tag`        | string | `"1.0.4"`                     | Init container image tag                                               |
| `server.imagePullSecrets`     | list   | `[]`                          | Component-level pull secrets                                           |

#### Server Configuration

| Key                                        | Type   | Default                       | Description                                                                           |
| ------------------------------------------ | ------ | ----------------------------- | ------------------------------------------------------------------------------------- |
| `server.config.listenAddress`              | string | `":80"`                       | Address and port the server listens on                                                |
| `server.config.exposedAddress`             | string | `""`                          | Public URL for peer connections — `https://host:port` (port required, see note below) |
| `server.config.stunPorts`                  | list   | `[3478]`                      | UDP ports for the embedded STUN server                                                |
| `server.config.metricsPort`                | int    | `9090`                        | Prometheus metrics port                                                               |
| `server.config.healthcheckAddress`         | string | `":9000"`                     | Health check endpoint address                                                         |
| `server.config.logLevel`                   | string | `"info"`                      | Log verbosity (debug, info, warn, error)                                              |
| `server.config.logFile`                    | string | `"console"`                   | Log output destination                                                                |
| `server.config.dataDir`                    | string | `"/var/lib/netbird"`          | Data directory for state and DB                                                       |
| `server.config.auth.issuer`                | string | `""`                          | OAuth2/OIDC issuer URL                                                                |
| `server.config.auth.signKeyRefreshEnabled` | bool   | `true`                        | Auto-refresh IdP signing keys                                                         |
| `server.config.auth.dashboardRedirectURIs` | list   | `[]`                          | Dashboard OAuth2 redirect URIs                                                        |
| `server.config.auth.cliRedirectURIs`       | list   | `["http://localhost:53000/"]` | CLI redirect URIs                                                                     |
| `server.config.relays.addresses`           | list   | `[]`                          | External relay URLs (e.g. `rels://relay.example.com:443`); empty = run embedded relay |
| `server.config.relays.credentialsTTL`      | string | `"12h"`                       | TTL for HMAC relay credentials handed to peers                                        |

By default the combined NetBird server runs an embedded relay on
`server.config.listenAddress` and advertises
`rels://<exposedAddress-host>:<port>` to peers, sharing
`server.secrets.authSecret` as the relay credential secret. Set
`server.config.relays.addresses` to point peers at an external relay
instead — this disables the embedded relay and uses
`server.secrets.relaySecret` for the credential secret.

#### Server Secrets

| Key                                              | Type   | Default           | Description                                                |
| ------------------------------------------------ | ------ | ----------------- | ---------------------------------------------------------- |
| `server.secrets.authSecret.secretName`           | string | `""`              | Existing Secret name (empty = auto-generate)               |
| `server.secrets.authSecret.secretKey`            | string | `"authSecret"`    | Key in the Secret                                          |
| `server.secrets.authSecret.autoGenerate`         | bool   | `true`            | Auto-generate on first install                             |
| `server.secrets.storeEncryptionKey.secretName`   | string | `""`              | Existing Secret name (empty = auto-generate)               |
| `server.secrets.storeEncryptionKey.secretKey`    | string | `"encryptionKey"` | Key in the Secret                                          |
| `server.secrets.storeEncryptionKey.autoGenerate` | bool   | `true`            | Auto-generate on first install                             |
| `server.secrets.relaySecret.secretName`          | string | `""`              | Existing Secret name (only consumed for external relay)    |
| `server.secrets.relaySecret.secretKey`           | string | `"relaySecret"`   | Key in the Secret                                          |
| `server.secrets.relaySecret.autoGenerate`        | bool   | `false`           | Auto-generate on first install (only when relays are set)  |

#### Server Storage

| Key                                    | Type   | Default             | Description                             |
| -------------------------------------- | ------ | ------------------- | --------------------------------------- |
| `server.persistentVolume.enabled`      | bool   | `true`              | Create a PVC for server data            |
| `server.persistentVolume.storageClass` | string | `""`                | Storage class (empty = cluster default) |
| `server.persistentVolume.accessModes`  | list   | `["ReadWriteOnce"]` | PVC access modes                        |
| `server.persistentVolume.size`         | string | `"1Gi"`             | PVC size                                |
| `server.persistentVolume.annotations`  | object | `{}`                | PVC annotations                         |

#### Server Networking

| Key                              | Type   | Default          | Description              |
| -------------------------------- | ------ | ---------------- | ------------------------ |
| `server.stunPort`                | int    | `3478`           | STUN UDP container port  |
| `server.service.type`            | string | `"ClusterIP"`    | Server service type      |
| `server.service.port`            | int    | `80`             | Server service port      |
| `server.stunService.type`        | string | `"LoadBalancer"` | STUN service type        |
| `server.stunService.port`        | int    | `3478`           | STUN service port        |
| `server.stunService.nodePort`    | int    | `null`           | Fixed NodePort number    |
| `server.stunService.annotations` | object | `{}`             | STUN service annotations |

#### Server Ingress

| Key                               | Type   | Default         | Description                                                                                                 |
| --------------------------------- | ------ | --------------- | ----------------------------------------------------------------------------------------------------------- |
| `server.ingress.enabled`          | bool   | `false`         | Create HTTP ingress (API + OAuth2). Mutually exclusive with `server.httpRoute`.                             |
| `server.ingress.className`        | string | `"nginx"`       | Ingress class                                                                                               |
| `server.ingress.annotations`      | object | `{}`            | Ingress annotations                                                                                         |
| `server.ingress.hosts`            | list   | `[]`            | Ingress host rules                                                                                          |
| `server.ingress.tls`              | list   | `[]`            | TLS configuration                                                                                           |
| `server.ingressGrpc.enabled`      | bool   | `false`         | Create gRPC ingress (Signal + Management). Mutually exclusive with `server.grpcRoute`.                      |
| `server.ingressGrpc.className`    | string | `"nginx"`       | Ingress class                                                                                               |
| `server.ingressGrpc.annotations`  | object | see values.yaml | GRPC backend annotations                                                                                    |
| `server.ingressGrpc.hosts`        | list   | `[]`            | Ingress host rules                                                                                          |
| `server.ingressGrpc.tls`          | list   | `[]`            | TLS configuration                                                                                           |
| `server.ingressRelay.enabled`     | bool   | `false`         | Create relay/WebSocket ingress. Mutually exclusive with `server.relayHttpRoute` and `server.relayTcpRoute`. |
| `server.ingressRelay.className`   | string | `"nginx"`       | Ingress class                                                                                               |
| `server.ingressRelay.annotations` | object | `{}`            | Ingress annotations                                                                                         |
| `server.ingressRelay.hosts`       | list   | `[]`            | Ingress host rules                                                                                          |
| `server.ingressRelay.tls`         | list   | `[]`            | TLS configuration                                                                                           |

#### Server Gateway API routes

Gateway API alternatives to the Ingress blocks above. Enabling both an
Ingress and its matching route block is a template-time error. TLS is
terminated at the referenced Gateway's listeners, not in these values.

| Key                                 | Type   | Default | Description                                                                           |
| ----------------------------------- | ------ | ------- | ------------------------------------------------------------------------------------- |
| `server.httpRoute.enabled`          | bool   | `false` | Create `HTTPRoute` for HTTP (API + OAuth2). Requires `parentRefs`.                    |
| `server.httpRoute.parentRefs`       | list   | `[]`    | Gateways to attach to (`name`, `namespace`, optional `sectionName`).                  |
| `server.httpRoute.hostnames`        | list   | `[]`    | HTTPRoute hostnames                                                                   |
| `server.httpRoute.rules`            | list   | `[]`    | `HTTPRoute.spec.rules`. Omitted `backendRefs` default to server Service on port 80.   |
| `server.httpRoute.annotations`      | object | `{}`    | Route annotations                                                                     |
| `server.httpRoute.labels`           | object | `{}`    | Extra labels                                                                          |
| `server.grpcRoute.enabled`          | bool   | `false` | Create `GRPCRoute` for Signal + Management. Works with plaintext h2c.                 |
| `server.grpcRoute.parentRefs`       | list   | `[]`    | Gateway parent refs                                                                   |
| `server.grpcRoute.hostnames`        | list   | `[]`    | GRPCRoute hostnames                                                                   |
| `server.grpcRoute.rules`            | list   | `[]`    | `GRPCRoute.spec.rules` (method or header matches)                                     |
| `server.grpcRoute.annotations`      | object | `{}`    | Route annotations                                                                     |
| `server.grpcRoute.labels`           | object | `{}`    | Extra labels                                                                          |
| `server.relayHttpRoute.enabled`     | bool   | `false` | Create `HTTPRoute` for relay + WebSocket (default Gateway API path).                  |
| `server.relayHttpRoute.parentRefs`  | list   | `[]`    | Gateway parent refs                                                                   |
| `server.relayHttpRoute.hostnames`   | list   | `[]`    | HTTPRoute hostnames                                                                   |
| `server.relayHttpRoute.rules`       | list   | `[]`    | `HTTPRoute.spec.rules`                                                                |
| `server.relayHttpRoute.annotations` | object | `{}`    | Route annotations                                                                     |
| `server.relayHttpRoute.labels`      | object | `{}`    | Extra labels                                                                          |
| `server.relayTcpRoute.enabled`      | bool   | `false` | Create `TCPRoute` (`v1alpha2`) for raw-TCP relay listeners.                           |
| `server.relayTcpRoute.parentRefs`   | list   | `[]`    | Gateway parent refs                                                                   |
| `server.relayTcpRoute.rules`        | list   | `[]`    | `TCPRoute.spec.rules`. Defaults to a single rule targeting server Service on port 80. |
| `server.relayTcpRoute.annotations`  | object | `{}`    | Route annotations                                                                     |
| `server.relayTcpRoute.labels`       | object | `{}`    | Extra labels                                                                          |

#### Server Pod

| Key                         | Type   | Default                  | Description                    |
| --------------------------- | ------ | ------------------------ | ------------------------------ |
| `server.resources`          | object | `{}`                     | CPU/memory requests and limits |
| `server.nodeSelector`       | object | `{}`                     | Node selector labels           |
| `server.tolerations`        | list   | `[]`                     | Pod tolerations                |
| `server.affinity`           | object | `{}`                     | Pod affinity rules             |
| `server.podAnnotations`     | object | `{}`                     | Pod annotations                |
| `server.podLabels`          | object | `{}`                     | Additional pod labels          |
| `server.podSecurityContext` | object | `{}`                     | Pod security context           |
| `server.securityContext`    | object | `{}`                     | Container security context     |
| `server.livenessProbe`      | object | TCP check on `http` port | Liveness probe                 |
| `server.readinessProbe`     | object | TCP check on `http` port | Readiness probe                |

### Dashboard

| Key                          | Type   | Default                 | Description                  |
| ---------------------------- | ------ | ----------------------- | ---------------------------- |
| `dashboard.replicaCount`     | int    | `1`                     | Number of dashboard replicas |
| `dashboard.image.repository` | string | `"netbirdio/dashboard"` | Dashboard image              |
| `dashboard.image.tag`        | string | `"v2.32.4"`             | Dashboard image tag          |
| `dashboard.image.pullPolicy` | string | `"IfNotPresent"`        | Image pull policy            |
| `dashboard.imagePullSecrets` | list   | `[]`                    | Component-level pull secrets |

#### Dashboard Configuration

| Key                                      | Type   | Default                         | Description                                  |
| ---------------------------------------- | ------ | ------------------------------- | -------------------------------------------- |
| `dashboard.config.mgmtApiEndpoint`       | string | `""`                            | Management API URL                           |
| `dashboard.config.mgmtGrpcApiEndpoint`   | string | `""`                            | Management gRPC URL                          |
| `dashboard.config.authAudience`          | string | `"netbird-dashboard"`           | OAuth2 audience                              |
| `dashboard.config.authClientId`          | string | `"netbird-dashboard"`           | OAuth2 client ID                             |
| `dashboard.config.authAuthority`         | string | `""`                            | OAuth2 authority / issuer URL                |
| `dashboard.config.useAuth0`              | string | `"false"`                       | Use Auth0 as IdP                             |
| `dashboard.config.authSupportedScopes`   | string | `"openid profile email groups"` | OAuth2 scopes                                |
| `dashboard.config.authRedirectUri`       | string | `"/nb-auth"`                    | Auth redirect path                           |
| `dashboard.config.authSilentRedirectUri` | string | `"/nb-silent-auth"`             | Silent auth redirect path                    |
| `dashboard.config.nginxSslPort`          | string | `"443"`                         | NGINX SSL port inside the container          |
| `dashboard.config.letsencryptDomain`     | string | `"none"`                        | Let's Encrypt domain ("none" = external TLS) |

#### Dashboard Secrets

| Key                                             | Type   | Default          | Description                                   |
| ----------------------------------------------- | ------ | ---------------- | --------------------------------------------- |
| `dashboard.secrets.authClientSecret.value`      | string | `""`             | Plain-text client secret (when no Secret ref) |
| `dashboard.secrets.authClientSecret.secretName` | string | `""`             | Existing Secret name                          |
| `dashboard.secrets.authClientSecret.secretKey`  | string | `"clientSecret"` | Key in the Secret                             |

#### Dashboard Extra

| Key                  | Type | Default | Description                      |
| -------------------- | ---- | ------- | -------------------------------- |
| `dashboard.extraEnv` | list | `[]`    | Additional environment variables |

#### Dashboard Networking

| Key                               | Type   | Default       | Description                                                                            |
| --------------------------------- | ------ | ------------- | -------------------------------------------------------------------------------------- |
| `dashboard.service.type`          | string | `"ClusterIP"` | Dashboard service type                                                                 |
| `dashboard.service.port`          | int    | `80`          | Dashboard service port                                                                 |
| `dashboard.ingress.enabled`       | bool   | `false`       | Create dashboard ingress. Mutually exclusive with `dashboard.httpRoute`.               |
| `dashboard.ingress.className`     | string | `"nginx"`     | Ingress class                                                                          |
| `dashboard.ingress.annotations`   | object | `{}`          | Ingress annotations                                                                    |
| `dashboard.ingress.hosts`         | list   | `[]`          | Ingress host rules                                                                     |
| `dashboard.ingress.tls`           | list   | `[]`          | TLS configuration                                                                      |
| `dashboard.httpRoute.enabled`     | bool   | `false`       | Create Gateway API `HTTPRoute` for the dashboard. Requires `parentRefs`.               |
| `dashboard.httpRoute.parentRefs`  | list   | `[]`          | Gateways to attach to                                                                  |
| `dashboard.httpRoute.hostnames`   | list   | `[]`          | HTTPRoute hostnames                                                                    |
| `dashboard.httpRoute.rules`       | list   | `[]`          | `HTTPRoute.spec.rules`. Omitted `backendRefs` default to dashboard Service on port 80. |
| `dashboard.httpRoute.annotations` | object | `{}`          | Route annotations                                                                      |
| `dashboard.httpRoute.labels`      | object | `{}`          | Extra labels                                                                           |

#### Dashboard Pod

| Key                            | Type   | Default      | Description                    |
| ------------------------------ | ------ | ------------ | ------------------------------ |
| `dashboard.resources`          | object | `{}`         | CPU/memory requests and limits |
| `dashboard.nodeSelector`       | object | `{}`         | Node selector labels           |
| `dashboard.tolerations`        | list   | `[]`         | Pod tolerations                |
| `dashboard.affinity`           | object | `{}`         | Pod affinity rules             |
| `dashboard.podAnnotations`     | object | `{}`         | Pod annotations                |
| `dashboard.podLabels`          | object | `{}`         | Additional pod labels          |
| `dashboard.podSecurityContext` | object | `{}`         | Pod security context           |
| `dashboard.securityContext`    | object | `{}`         | Container security context     |
| `dashboard.livenessProbe`      | object | HTTP GET `/` | Liveness probe                 |
| `dashboard.readinessProbe`     | object | HTTP GET `/` | Readiness probe                |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Ingress Controller   ─or─   Gateway API Gateway             │
│                                                             │
│  /api, /oauth2 ─────┐   HTTPRoute      ──► Server Pod :80   │
│  /signalexchange/*, /management/*   GRPCRoute               │
│                     ├─────────────► Server Pod :80          │
│  /relay, /ws-proxy ─┘   HTTPRoute / TCPRoute                │
│                                                             │
│  / ──────────────────── HTTPRoute ──► Dashboard Pod :80     │
└─────────────────────────────────────────────────────────────┘
                                        │
                               STUN Service :3478/UDP
                               (LoadBalancer — separate IP,
                                cannot use HTTP Ingress/Gateway)
```

Each traffic class picks **either** an Ingress **or** a Gateway API route,
independently, via `server.ingress{,Grpc,Relay}` / `server.httpRoute` /
`server.grpcRoute` / `server.relayHttpRoute` / `server.relayTcpRoute` and
`dashboard.ingress` / `dashboard.httpRoute`. Enabling both for the same
class is rejected at template time.

## Upstream Source

This chart is based on the [NetBird](https://github.com/netbirdio/netbird) project. See the `sources` field in `Chart.yaml` for details.

## License

Apache License 2.0 — see [LICENSE](../../LICENSE).
