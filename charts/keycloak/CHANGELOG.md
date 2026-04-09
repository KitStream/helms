# Changelog

All notable changes to the Keycloak Helm chart will be documented in this file.

## Unreleased

### Fixed

- Fix broken chart icon URL — upstream Keycloak moved `keycloak_icon_512px.svg` to `icon.svg` (#64)

### Changed

- Bump Keycloak appVersion from 26.5.7 to 26.6.0 (feature release)
  - JWT Authorization Grant, Federated client authentication, Workflows now fully supported
  - Zero-downtime patch releases
  - See [upstream release notes](https://github.com/keycloak/keycloak/releases/tag/26.6.0) for details
