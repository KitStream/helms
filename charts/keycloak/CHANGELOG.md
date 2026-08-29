# Changelog

All notable changes to the Keycloak Helm chart will be documented in this file.

## Unreleased

### Changed

- Use `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` for the
  initial admin instead of `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`,
  which upstream has deprecated and logs a warning for on every start
  (`KC-SERVICES0110`). No values change is required — `admin.username` and
  `admin.password` are unchanged; only the environment variable names the
  chart emits differ. As before, these apply only when bootstrapping a
  fresh database.

### Security

- Bump Keycloak appVersion from 26.6.3 to 26.7.2 (#115, #120, #129, #133)
  - 26.7.2 fixes CVE-2026-59888 / CVE-2026-59889 (jackson-databind) and
    26.7.0 fixes CVE-2026-9796 (admin role rename TOCTOU allowing
    realm-wide privilege escalation from `manage-clients`)
  - 26.7.2 also fixes an upgrade failure where the stateless cluster
    provider captured a null NodeInfo before `postInit` when preview
    features were enabled — this is why the chart moves straight to
    26.7.2 rather than 26.7.0
  - No `KC_*` option used by this chart changed. Options removed upstream
    in 26.7.0 (persistent-session batching, `token-exchange-external-internal:v2`)
    are not used here, and ports, health endpoints, and the container
    entrypoint are unchanged
  - See upstream release notes for
    [26.7.0](https://github.com/keycloak/keycloak/releases/tag/26.7.0) and
    [26.7.2](https://github.com/keycloak/keycloak/releases/tag/26.7.2)

## [26.6.3] — 2026-06-11

### Fixed

- Set `publishNotReadyAddresses: true` on the JGroups headless service.
  Without it, replicas cannot resolve each other via DNS until they are
  Ready, so simultaneously started pods form singleton clusters that merge
  late (split-brain). During the split window cache invalidations are lost
  between replicas — observed as HTTP 403 from one replica for a realm
  created via another. This matches what the upstream Keycloak operator
  does for its discovery service.

### Security

- Bump Keycloak appVersion from 26.6.1 to 26.6.3 (security and bugfix releases) (#96)
  - 26.6.2 and 26.6.3 together fix ~32 CVEs, including session fixation,
    redirect-URI bypass, SSRF, and refresh-token reuse issues
  - 26.6.3 fixes a bug where 26.6.x could exit with code 1 after async realm
    migration, and adds a startup warning for missing database indexes
  - No changes to `KC_*` options, ports, health endpoints, or the container
    entrypoint
  - See upstream release notes for
    [26.6.2](https://github.com/keycloak/keycloak/releases/tag/26.6.2) and
    [26.6.3](https://github.com/keycloak/keycloak/releases/tag/26.6.3)
