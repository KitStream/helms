# Security Policy

## Supported Versions

| Chart   | Version | Supported |
|---------|---------|-----------|
| netbird | 0.1.x   | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email security reports to the maintainers via [GitHub's private vulnerability reporting](https://github.com/KitStream/helms/security/advisories/new).

Include:

- A description of the vulnerability
- Steps to reproduce
- Affected chart(s) and version(s)
- Any potential impact

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation within 7 days for critical issues.

## Security Practices

This project follows security best practices for Helm charts:

- **Non-root containers**: All containers run as non-root by default
- **Read-only root filesystem**: Init containers use read-only root filesystems
- **No privilege escalation**: `allowPrivilegeEscalation: false` on all containers
- **Minimal capabilities**: All Linux capabilities are dropped unless explicitly required
- **Secret management**: Sensitive values are injected via Kubernetes Secrets, never hardcoded
- **No shell in init containers**: Uses [Initium](https://github.com/KitStream/initium) (FROM scratch image) instead of shell-based init containers
- **Pinned image versions**: All image tags are pinned to specific versions

## Upstream Vulnerabilities

For vulnerabilities in the upstream applications (e.g., NetBird), please report them to the respective upstream projects:

- NetBird: https://github.com/netbirdio/netbird/security
