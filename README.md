# Helms

[![CI](https://github.com/KitStream/helms/actions/workflows/ci.yaml/badge.svg)](https://github.com/KitStream/helms/actions/workflows/ci.yaml)
[![Release](https://github.com/KitStream/helms/actions/workflows/release.yaml/badge.svg)](https://github.com/KitStream/helms/actions/workflows/release.yaml)
[![License](https://img.shields.io/github/license/KitStream/helms)](LICENSE)
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/kitstream)](https://artifacthub.io/packages/search?repo=kitstream)

Production-ready Helm charts for self-hosted infrastructure, maintained by [KitStream](https://github.com/KitStream).

## Charts

| Chart                      | Description                                                                                   | Version |
|----------------------------|-----------------------------------------------------------------------------------------------|---------|
| [netbird](charts/netbird/) | Deploy [NetBird](https://netbird.io) VPN (management, signal, dashboard, relay) on Kubernetes | `0.1.0` |

## Quick Start

### Install from OCI Registry

```bash
helm install netbird oci://ghcr.io/kitstream/helms/netbird \
  --version 0.1.0 \
  -n netbird --create-namespace \
  -f my-values.yaml
```

### Install from Source

```bash
git clone https://github.com/KitStream/helms.git
helm install netbird helms/charts/netbird \
  -n netbird --create-namespace \
  -f my-values.yaml
```

See each chart's README for detailed configuration.

## What Makes These Charts Different

- **No shell in init containers** — Uses [Initium](https://github.com/KitStream/initium) (FROM scratch) instead of Alpine + shell scripts. No package manager, no shell escaping issues, smaller attack surface.
- **Hardened by default** — Non-root, read-only root filesystem, all capabilities dropped, no privilege escalation.
- **Structured configuration** — No raw DSN strings. Provide `database.host`, `database.user`, etc. and the chart builds it for you.
- **Automatic database readiness** — Init containers wait for your database and create it if it doesn't exist. No manual setup, no race conditions.
- **Comprehensive testing** — Unit tests (helm-unittest) + E2E tests across SQLite, PostgreSQL, and MySQL backends on every PR.

## Prerequisites

- [Helm](https://helm.sh/docs/intro/install/) v3.8+ (OCI support)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured for your target cluster
- Kubernetes 1.24+ (1.28+ for SQLite PAT seeding)

## Contributing

We welcome contributions! Please read our [Contributing Guide](CONTRIBUTING.md) before submitting pull requests.

## Security

See [SECURITY.md](SECURITY.md) for our security policy and reporting instructions.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Copyright 2026 KitStream
