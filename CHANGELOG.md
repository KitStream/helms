# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- **OIDC/SSO configuration**: New `oidc.*` values for structured OIDC/SSO
  configuration. When `oidc.enabled: true`, the chart renders `http:`,
  `deviceAuthFlow:`, `pkceAuthFlow:`, and `idpConfig:` sections in the
  server config.yaml. Supports all NetBird-supported IdP managers: keycloak,
  auth0, azure, zitadel, okta, authentik, google, jumpcloud, dex, embedded.
- `oidc.audience`, `oidc.userIdClaim`, `oidc.configEndpoint`,
  `oidc.authKeysLocation` for HttpServerConfig fields.
- `oidc.deviceAuthFlow.*` for Device Authorization Flow (RFC 8628) — CLI
  clients.
- `oidc.pkceAuthFlow.*` for PKCE Authorization Flow (RFC 7636) — dashboard
  and web app clients. Supports both plain-text and secret-ref client secrets.
- `oidc.idpManager.*` for IdP Manager configuration (server-side user/group
  sync). Provider-specific credentials rendered under the correct YAML key
  based on `oidc.idpManager.managerType` (e.g. `keycloakClientCredentials`,
  `auth0ClientCredentials`, `azureClientCredentials`).
- OIDC secret values (`IDP_CLIENT_SECRET`, `PKCE_CLIENT_SECRET`) injected
  via Kubernetes Secrets using the existing Initium render pipeline.
- Dashboard `AUTH_AUTHORITY` falls back to `server.config.auth.issuer` when
  `dashboard.config.authAuthority` is empty.
- E2E test with Keycloak deployed in-cluster: verifies OIDC middleware,
  token acquisition via direct grant, and authenticated API access.
- E2E test with Zitadel + PostgreSQL deployed in-cluster: bootstraps
  project/apps/service user via Management API, verifies OIDC middleware,
  OIDC discovery, and client_credentials token acquisition.
- Unit tests for OIDC config rendering, secret injection, provider
  credentials key mapping, and dashboard fallback (190 tests total).

- **PAT seeding**: Optional Personal Access Token seeding via `pat.*` values.
  When `pat.enabled: true`, a service user account and PAT are seeded into
  the database using Initium's `seed` command. The seed waits for the server
  to create its schema (GORM AutoMigrate), then idempotently inserts account,
  user, and PAT records.
- **SQLite**: PAT seed runs as a Kubernetes native sidecar (init container with
  `restartPolicy: Always`, K8s 1.28+) in the server Deployment. The sidecar
  uses Initium's `--sidecar` flag to stay alive after seeding, maintaining
  full pod readiness (`2/2 Running`). This avoids ReadWriteOnce PVC
  multi-attach issues that prevent a separate Job from mounting the PVC.
- **PostgreSQL/MySQL**: PAT seed runs as a post-install/post-upgrade Helm hook
  Job with a `wait-for` init container for server TCP readiness.
- PAT seed spec uses `wait_for` to wait for `accounts`, `users`, and
  `personal_access_tokens` tables before inserting data.
- PAT seed data uses `unique_key` for idempotent inserts (safe on re-installs).
- PAT seed ConfigMap is a regular release resource for SQLite and a Helm hook
  for external databases.
- E2E tests extended to verify PAT authentication with `GET /api/groups`
  across all three database backends (SQLite, PostgreSQL, MySQL).
- Unit tests for PAT seed Job, ConfigMap, and sidecar templates.
- Upgraded Initium init container image to v1.0.4 (adds `--sidecar` flag for
  keeping the process alive after task completion, SHA256/base64 template
  filters, PostgreSQL text primary key fix).

### Changed

- **Breaking:** Removed `pat.secret.hashedTokenKey` from PAT configuration. The
  SHA256 hash is now computed automatically at seed time by Initium v1.0.4 using
  MiniJinja's `sha256` and `base64encode` filters. Users only need to supply the
  plaintext PAT token in their Kubernetes Secret.
  **Migration:** Remove the `hashedToken` key from your PAT Secret and the
  `pat.secret.hashedTokenKey` from your values. Only `pat.secret.tokenKey` (default: `"token"`) is needed.
- **Breaking:** Replaced raw DSN secret (`server.secrets.storeDsn`) with structured
  `database.*` configuration. The chart now constructs the DSN internally from
  `database.type`, `database.host`, `database.port`, `database.user`, `database.name`,
  and `database.passwordSecret`. Users no longer need to build DSN strings.
- **Breaking:** Removed `server.config.store.engine`. Use `database.type` instead
  (`sqlite`, `postgresql`, `mysql`).

### Added

- Structured database configuration via `database.*` values with per-engine defaults
  (port 5432 for postgresql, 3306 for mysql).
- `database.sslMode` for PostgreSQL SSL mode control (default: `disable`).
- Initium `wait-for` init container: waits for external database to be reachable
  before starting the server (TCP probe with 120s timeout and exponential backoff).
- Initium `seed` init container: creates the target database if it does not exist
  via a declarative seed spec (`create_if_missing: true`).
- `DB_PASSWORD` environment variable injected into config-init via `secretKeyRef`
  for DSN construction at render time.
- Seed spec rendered as `seed.yaml` in the server ConfigMap for non-sqlite engines.
- Unit tests for init container ordering, env var injection, and database-specific
  rendering (120 tests, up from 110).
- CHANGELOG.md.

