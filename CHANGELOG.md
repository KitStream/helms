# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- **PAT seeding**: Optional Personal Access Token seeding via `pat.*` values.
  When `pat.enabled: true`, a post-install/post-upgrade Helm hook Job seeds
  a service user account and PAT into the database using Initium's `seed` command.
  The Job waits for the server to create its schema (GORM AutoMigrate), then
  idempotently inserts account, user, and PAT records.
- PAT seed Job uses `wait-for` init container to wait for server TCP readiness
  before seeding.
- PAT seed spec uses `wait_for` to wait for `accounts`, `users`, and
  `personal_access_tokens` tables before inserting data.
- PAT seed data uses `unique_key` for idempotent inserts (safe on re-installs).
- PAT seed ConfigMap and Job are Helm hooks (post-install, post-upgrade) with
  `before-hook-creation` delete policy.
- E2E tests extended to verify PAT authentication with `GET /api/groups`
  across all three database backends (SQLite, PostgreSQL, MySQL).
- 28 new unit tests for PAT seed Job and ConfigMap templates.
- Upgraded Initium init container image to v1.0.1 (fixes PostgreSQL inserts
  on tables with text primary keys).

### Changed

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

