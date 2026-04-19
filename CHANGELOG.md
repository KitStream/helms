# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- **netbird**: Add `server.stunService.nodePort` value to allow specifying a
  fixed NodePort number when `server.stunService.type` is `NodePort`.

## [0.4.2] — 2026-04-21

### Added

- **netbird**: Fail-fast Helm template validation that rejects
  `server.config.exposedAddress` values without an explicit port (e.g.
  `https://netbird.example.com`). NetBird clients require the port — without
  it the daemon fails with `missing port in address`. Use
  `https://netbird.example.com:443` instead. Fixes #75.

### Changed

- **netbird**: Bump appVersion from 0.68.2 to 0.68.3.
  See [v0.68.3 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.68.3) (#71).
- **netbird**: README and `values.yaml` examples now show
  `exposedAddress` with an explicit `:443` port and document that the
  port is required even when it matches the scheme default.

## [0.4.1] — 2026-04-14

### Added

- **netbird**: Document STUN networking setup in README — explains why STUN
  needs a separate service (UDP), and covers options for LoadBalancer,
  shared static IP, and NodePort configurations (#67).

### Changed

- **netbird**: Bump appVersion from 0.68.1 to 0.68.2.
  See [v0.68.2 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.68.2) (#69).

## [0.4.0] — 2026-04-09

### Changed

- **netbird**: Bump appVersion from 0.67.4 to 0.68.1.
  See [v0.68.1 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.68.1).

## [0.3.4] — 2026-04-09

### Changed

- **netbird**: Bump appVersion from 0.67.1 to 0.67.4.
  See [v0.67.4 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.67.4).

## [0.3.2] — 2026-03-28

### Changed

- **netbird**: Bump appVersion from 0.66.4 to 0.67.0.
  See [v0.67.0 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.67.0).

### Fixed

- **netbird**: Bump Initium from 2.0.0 to 2.1.0 to fix a regression in
  database creation on blank PostgreSQL/MySQL instances.
- **e2e**: PostgreSQL and MySQL e2e tests no longer pre-create the `netbird`
  database, so Initium's `create_if_missing` path is properly exercised.
- **netbird**: Fix seed spec connection strings failing when the database
  password contains URL-special characters (`@`, `%`, `:`, etc.).
  Seed specs now use Initium v2's structured connection config instead of
  URL strings, so passwords with any characters work without encoding.
  E2E tests now use a password containing `%40` to guard against
  regressions. Fixes #32.

### Changed

- **netbird**: Bump appVersion from 0.66.3 to 0.66.4 (chart version 0.2.1).
  Bug fixes and improvements; no breaking changes. See
  [v0.66.4 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.66.4).
- **netbird**: Bump Initium from 1.2.0 to 2.0.0. Uses structured
  database connection config (no more URL-encoded passwords).
- **Upstream version check**: Fix duplicate issue creation caused by GitHub's
  `--search` failing to match titles with special characters (e.g. `→`). The
  deduplication check now filters by the `autorelease` label instead.

## [0.1.2] — 2026-03-10

### Changed

- **netbird**: Bump appVersion from 0.65.3 to 0.66.3 (chart version 0.1.2).
  Bug fixes and improvements; no breaking changes. See
  [v0.66.3 release notes](https://github.com/netbirdio/netbird/releases/tag/v0.66.3).

### Fixed

- **Upstream version check workflow**: The `autorelease` label is now created
  automatically if it does not exist, fixing the scheduled workflow failure
  (`could not add label: 'autorelease' not found`).

### Added

- **Automated upstream version tracking**: New scheduled GitHub Actions workflow
  (`.github/workflows/upstream-check.yaml`) that runs daily to detect new
  releases from upstream repositories and opens a GitHub issue when an update
  is available. Currently tracks NetBird server (`netbirdio/netbird`).
- `.upstream-monitor.yaml` configuration file mapping upstream GitHub
  repositories to Helm chart version fields. Add new charts or sources by
  extending this file.
- `ci/scripts/upstream-check.sh` script that reads the monitor config, queries
  the GitHub API for latest releases, compares with current chart versions,
  and creates GitHub issues for available updates. Supports `DRY_RUN=true`
  for preview mode.
- Workflow supports manual trigger via `workflow_dispatch` with optional
  dry-run input.

## [0.1.1] — 2026-02-26

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
