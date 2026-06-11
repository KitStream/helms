# Changelog

All notable changes to the Keycloak Helm chart will be documented in this file.

## Unreleased

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
