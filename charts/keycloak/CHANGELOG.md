# Changelog

All notable changes to the Keycloak Helm chart will be documented in this file.

## Unreleased

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
