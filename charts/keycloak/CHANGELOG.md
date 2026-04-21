# Changelog

All notable changes to the Keycloak Helm chart will be documented in this file.

## Unreleased

### Fixed

- Fix broken chart icon URL — upstream Keycloak moved `keycloak_icon_512px.svg` to `icon.svg` (#64)

### Security

- Bump Keycloak appVersion from 26.6.0 to 26.6.1 (security and bugfix release)
  - CVE-2026-4366: Blind Server-Side Request Forgery (SSRF) via HTTP redirect handling
  - CVE-2026-4633: User enumeration via identity-first login
  - Includes additional bugfixes (see upstream release notes)
  - See [upstream release notes](https://github.com/keycloak/keycloak/releases/tag/26.6.1) for details
