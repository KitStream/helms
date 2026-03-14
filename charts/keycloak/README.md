# Keycloak Helm Chart

[![CI](https://github.com/KitStream/helms/actions/workflows/ci.yaml/badge.svg)](https://github.com/KitStream/helms/actions/workflows/ci.yaml)
[![Chart Version](https://img.shields.io/badge/chart-26.5.0-blue)](https://github.com/KitStream/helms/releases)
[![App Version](https://img.shields.io/badge/keycloak-26.5.0-green)](https://github.com/keycloak/keycloak)

A Helm chart for deploying [Keycloak](https://www.keycloak.org) IAM using the upstream `quay.io/keycloak/keycloak` image on Kubernetes.

## Overview

This chart deploys Keycloak directly from the upstream container image with native `KC_*` environment variable configuration. It supports:

- **Databases**: PostgreSQL, MySQL, MSSQL, or embedded H2 (dev mode)
- **Clustering**: JDBC-PING (default) or Kubernetes DNS-PING via headless service
- **Build optimization**: Optional init container for `kc.sh build` to speed up startup
- **Observability**: Health endpoints on a dedicated management port, Prometheus metrics, and optional ServiceMonitor

## Prerequisites

- Kubernetes 1.24+
- Helm 3.x
- An external database for production use (PostgreSQL recommended)

## Installation

### From OCI Registry (recommended)

```bash
helm install keycloak oci://ghcr.io/kitstream/helms/keycloak \
  --version 26.5.0 \
  -n keycloak --create-namespace \
  -f my-values.yaml
```

### From Source

```bash
helm install keycloak ./charts/keycloak \
  -n keycloak --create-namespace \
  -f my-values.yaml
```

## Minimal Configuration Examples

### Development (embedded H2)

No external database required. **Not suitable for production.**

```yaml
database:
  type: dev

admin:
  username: admin
  password:
    secretName: keycloak-admin-password
    secretKey: password
```

### PostgreSQL (production)

```yaml
hostname: keycloak.example.com
hostnameStrict: true

database:
  type: postgresql
  host: postgres.database.svc.cluster.local
  port: 5432
  user: keycloak
  name: keycloak
  password:
    secretName: keycloak-db-password
    secretKey: password

admin:
  username: admin
  password:
    secretName: keycloak-admin-password
    secretKey: password

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: keycloak.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: keycloak-tls
      hosts:
        - keycloak.example.com
```

### Multi-Replica with Kubernetes DNS-PING

```yaml
replicaCount: 3

hostname: keycloak.example.com
hostnameStrict: true

database:
  type: postgresql
  host: postgres.database.svc.cluster.local
  port: 5432
  user: keycloak
  name: keycloak
  password:
    secretName: keycloak-db-password
    secretKey: password

cache:
  stack: kubernetes

admin:
  username: admin
  password:
    secretName: keycloak-admin-password
    secretKey: password
```

## Creating Secrets

### Admin Password

```bash
kubectl create secret generic keycloak-admin-password \
  --from-literal=password='YOUR_SECURE_PASSWORD' \
  -n keycloak
```

### Database Password

```bash
kubectl create secret generic keycloak-db-password \
  --from-literal=password='YOUR_DB_PASSWORD' \
  -n keycloak
```

## Hostname Configuration

Keycloak 26 requires explicit hostname configuration for production mode:

- **`hostname`**: Set to your public Keycloak URL (e.g. `keycloak.example.com`)
- **`hostnameStrict`**: Set to `true` when `hostname` is configured to prevent dynamic hostname resolution from request headers. Defaults to `false` so Keycloak can start without a hostname (dev/testing).

If `hostnameStrict` is `true` and no `hostname` is set, Keycloak will refuse to start.

## Clustering

The chart supports two cache stacks for multi-replica deployments:

| Stack        | Description                                                              | Default |
| ------------ | ------------------------------------------------------------------------ | ------- |
| `jdbc-ping`  | Uses the configured database for node discovery. No extra config needed. | Yes     |
| `kubernetes` | Uses DNS-PING via the headless service for JGroups discovery.            | No      |

In dev mode (`database.type: dev`), clustering is disabled (`KC_CACHE=local`) since the embedded H2 database cannot be shared across replicas.

## Build Optimization

By default, Keycloak runs an auto-build at startup in production mode (`start`), which can take 2-5 minutes. To speed up startup, enable the build init container:

```yaml
build:
  enabled: true
```

This runs `kc.sh build` in an init container and passes `--optimized` to the main container, reducing startup time to seconds.

## Values Reference

### Global

| Key                          | Type   | Default | Description                      |
| ---------------------------- | ------ | ------- | -------------------------------- |
| `nameOverride`               | string | `""`    | Override the chart name          |
| `fullnameOverride`           | string | `""`    | Fully override the resource name |
| `imagePullSecrets`           | list   | `[]`    | Global image pull secrets        |
| `serviceAccount.create`      | bool   | `true`  | Create a ServiceAccount          |
| `serviceAccount.annotations` | object | `{}`    | ServiceAccount annotations       |
| `serviceAccount.name`        | string | `""`    | ServiceAccount name override     |

### Image

| Key                | Type   | Default                       | Description                 |
| ------------------ | ------ | ----------------------------- | --------------------------- |
| `image.repository` | string | `"quay.io/keycloak/keycloak"` | Container image repository  |
| `image.tag`        | string | `""` (appVersion)             | Image tag                   |
| `image.pullPolicy` | string | `"IfNotPresent"`              | Image pull policy           |
| `replicaCount`     | int    | `1`                           | Number of Keycloak replicas |

### Database

| Key                            | Type   | Default      | Description                                             |
| ------------------------------ | ------ | ------------ | ------------------------------------------------------- |
| `database.type`                | string | `"dev"`      | Database type (`postgresql`, `mysql`, `mssql`, `dev`)   |
| `database.host`                | string | `""`         | Database hostname (required for external databases)     |
| `database.port`                | string | `""`         | Database port (auto-defaults: 5432/3306/1433)           |
| `database.name`                | string | `"keycloak"` | Database name                                           |
| `database.user`                | string | `""`         | Database username                                       |
| `database.password.secretName` | string | `""`         | Secret containing the database password                 |
| `database.password.secretKey`  | string | `"password"` | Key in the Secret                                       |
| `database.poolMinSize`         | string | `""`         | Connection pool minimum size                            |
| `database.poolInitialSize`     | string | `""`         | Connection pool initial size                            |
| `database.poolMaxSize`         | string | `""`         | Connection pool maximum size                            |
| `database.sslMode`             | string | `""`         | SSL mode for PostgreSQL (e.g. `verify-full`, `require`) |

### Hostname & Proxy

| Key              | Type   | Default | Description                                                              |
| ---------------- | ------ | ------- | ------------------------------------------------------------------------ |
| `hostname`       | string | `""`    | Public hostname (maps to `KC_HOSTNAME`)                                  |
| `hostnameAdmin`  | string | `""`    | Separate admin console hostname (maps to `KC_HOSTNAME_ADMIN`)            |
| `hostnameStrict` | bool   | `false` | Disable dynamic hostname from request headers (set `true` with hostname) |
| `proxyHeaders`   | string | `""`    | Proxy header mode: `xforwarded` or `forwarded`                           |
| `httpEnabled`    | bool   | `true`  | Enable HTTP listener (required for edge-terminated TLS)                  |

### TLS

| Key              | Type   | Default | Description                                 |
| ---------------- | ------ | ------- | ------------------------------------------- |
| `tls.enabled`    | bool   | `false` | Enable TLS passthrough (mount cert and key) |
| `tls.secretName` | string | `""`    | Secret containing `tls.crt` and `tls.key`   |

### Clustering

| Key           | Type   | Default       | Description                                        |
| ------------- | ------ | ------------- | -------------------------------------------------- |
| `cache.stack` | string | `"jdbc-ping"` | Cache stack: `jdbc-ping` (default) or `kubernetes` |

### Admin Credentials

| Key                         | Type   | Default      | Description                               |
| --------------------------- | ------ | ------------ | ----------------------------------------- |
| `admin.username`            | string | `""`         | Admin username (maps to `KEYCLOAK_ADMIN`) |
| `admin.password.secretName` | string | `""`         | Secret containing the admin password      |
| `admin.password.secretKey`  | string | `"password"` | Key in the Secret                         |

### Observability

| Key                                    | Type   | Default  | Description                         |
| -------------------------------------- | ------ | -------- | ----------------------------------- |
| `healthEnabled`                        | bool   | `true`   | Enable health endpoints             |
| `metrics.enabled`                      | bool   | `true`   | Enable Prometheus metrics           |
| `metrics.serviceMonitor.enabled`       | bool   | `false`  | Create a ServiceMonitor resource    |
| `metrics.serviceMonitor.labels`        | object | `{}`     | Additional ServiceMonitor labels    |
| `metrics.serviceMonitor.interval`      | string | `""`     | Scrape interval                     |
| `metrics.serviceMonitor.scrapeTimeout` | string | `""`     | Scrape timeout                      |
| `logLevel`                             | string | `"info"` | Log level (`debug`, `info`, `warn`) |

### Build Optimization

| Key             | Type | Default | Description                         |
| --------------- | ---- | ------- | ----------------------------------- |
| `build.enabled` | bool | `false` | Run `kc.sh build` in init container |

### Extra Configuration

| Key                  | Type   | Default | Description                                 |
| -------------------- | ------ | ------- | ------------------------------------------- |
| `extraEnvVars`       | list   | `[]`    | Additional environment variables            |
| `extraEnvVarsSecret` | string | `""`    | Existing Secret to mount as env vars        |
| `extraVolumes`       | list   | `[]`    | Additional volumes                          |
| `extraVolumeMounts`  | list   | `[]`    | Additional volume mounts                    |
| `features`           | string | `""`    | Comma-separated Keycloak features to enable |

### Persistent Storage

| Key                        | Type   | Default             | Description                            |
| -------------------------- | ------ | ------------------- | -------------------------------------- |
| `persistence.enabled`      | bool   | `false`             | Enable PVC for custom themes/providers |
| `persistence.storageClass` | string | `""`                | Storage class                          |
| `persistence.accessModes`  | list   | `["ReadWriteOnce"]` | PVC access modes                       |
| `persistence.size`         | string | `"1Gi"`             | Volume size                            |
| `persistence.annotations`  | object | `{}`                | PVC annotations                        |

### Services

| Key                           | Type   | Default       | Description                        |
| ----------------------------- | ------ | ------------- | ---------------------------------- |
| `service.type`                | string | `"ClusterIP"` | Service type                       |
| `service.httpPort`            | int    | `8080`        | HTTP port                          |
| `service.managementPort`      | int    | `9000`        | Management port (health + metrics) |
| `service.annotations`         | object | `{}`          | Service annotations                |
| `headlessService.jgroupsPort` | int    | `7800`        | JGroups clustering port            |
| `headlessService.annotations` | object | `{}`          | Headless service annotations       |

### Ingress

| Key                   | Type   | Default | Description             |
| --------------------- | ------ | ------- | ----------------------- |
| `ingress.enabled`     | bool   | `false` | Create Ingress resource |
| `ingress.className`   | string | `""`    | Ingress class name      |
| `ingress.annotations` | object | `{}`    | Ingress annotations     |
| `ingress.hosts`       | list   | `[]`    | Ingress host rules      |
| `ingress.tls`         | list   | `[]`    | TLS configuration       |

### Probes

| Key              | Type   | Default                                       | Description     |
| ---------------- | ------ | --------------------------------------------- | --------------- |
| `startupProbe`   | object | HTTP GET `/health/started` on management:9000 | Startup probe   |
| `livenessProbe`  | object | HTTP GET `/health/live` on management:9000    | Liveness probe  |
| `readinessProbe` | object | HTTP GET `/health/ready` on management:9000   | Readiness probe |

### Pod Scheduling & Metadata

| Key                  | Type   | Default | Description                      |
| -------------------- | ------ | ------- | -------------------------------- |
| `resources`          | object | `{}`    | CPU/memory requests and limits   |
| `nodeSelector`       | object | `{}`    | Node selector labels             |
| `tolerations`        | list   | `[]`    | Pod tolerations                  |
| `affinity`           | object | `{}`    | Pod affinity rules               |
| `podAnnotations`     | object | `{}`    | Pod annotations                  |
| `podLabels`          | object | `{}`    | Additional pod labels            |
| `podSecurityContext` | object | `{}`    | Pod-level security context       |
| `securityContext`    | object | `{}`    | Container-level security context |

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                   Ingress Controller                  │
│                                                       │
│  / ────────────────────────► Keycloak Pod             │
│                               ├─ :8080 HTTP           │
│                               ├─ :9000 Management     │
│                               │   (health + metrics)  │
│                               └─ :7800 JGroups        │
│                                   (clustering)        │
└──────────────────────────────────────────────────────┘
         │                              │
    Headless Service              Main Service
    (JGroups DNS-PING)         (HTTP + Management)
```

## Upstream Source

This chart deploys the upstream [Keycloak](https://github.com/keycloak/keycloak) image from `quay.io/keycloak/keycloak`. See the `sources` field in `Chart.yaml` for details.

## License

Apache License 2.0 — see [LICENSE](../../LICENSE).
