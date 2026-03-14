# Contributing to Helms

Thank you for your interest in contributing to the KitStream Helms repository! This document provides guidelines and information for contributors.

## How to Contribute

### Reporting Issues

- Use [GitHub Issues](https://github.com/KitStream/helms/issues) to report bugs or request features.
- Search existing issues before creating a new one to avoid duplicates.
- Provide as much detail as possible, including Helm and Kubernetes versions.

### Submitting Changes

1. **Fork** the repository and create a feature branch from `main`:
   ```bash
   git checkout -b feature/my-chart-improvement
   ```

2. **Make your changes** following the guidelines below.

3. **Test** your chart locally:
   ```bash
   helm lint charts/<chart-name>
   helm template charts/<chart-name>
   ```

4. **Commit** with clear, descriptive messages:
   ```bash
   git commit -m "feat(chart-name): add support for ingress annotations"
   ```

5. **Push** your branch and open a **Pull Request** against `main`.

## Chart Guidelines

### New Charts

When adding a new chart:

- Place the chart under `charts/<chart-name>/`.
- Include a `Chart.yaml` with complete metadata (name, version, appVersion, description, maintainers).
- Provide sensible defaults in `values.yaml` with thorough inline comments.
- Include a `README.md` documenting all configurable values and usage examples.
- Add a `NOTES.txt` template to display post-install instructions.
- Follow [Helm best practices](https://helm.sh/docs/chart_best_practices/).

### Upgrading Existing Charts

When bringing in or upgrading a chart from the community:

- Document the upstream source and version in `Chart.yaml` (use the `sources` field).
- Clearly describe what modifications were made and why in the PR description.
- Preserve upstream license information where applicable.

### General Standards

- Run `dprint fmt` to format markdown files before submitting.
- Use `helm lint` to validate charts before submitting.
- Use `helm template` to verify rendered manifests.
- Follow [Kubernetes naming conventions](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/).
- Use labels consistently: `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/version`, `app.kubernetes.io/managed-by`.
- Parameterise resource requests/limits, replica counts, and image references in `values.yaml`.
- Avoid hard-coding namespaces in templates.

## Commit Message Convention

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat(chart-name): description` — new feature
- `fix(chart-name): description` — bug fix
- `docs(chart-name): description` — documentation change
- `chore: description` — maintenance tasks

## Code of Conduct

Be respectful and constructive. We are committed to providing a welcoming and inclusive environment for everyone.

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
