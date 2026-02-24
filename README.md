# Helms

A curated collection of Helm charts maintained by [KitStream](https://github.com/KitStream). This repository serves as a home for both green-field Helm charts and upgraded or improved charts sourced from the community.

## Repository Structure

```
helms/
├── charts/           # Individual Helm charts, each in its own subdirectory
├── CONTRIBUTING.md   # Contribution guidelines
├── LICENSE           # Apache License 2.0
└── README.md         # This file
```

Each chart lives in its own directory under `charts/` and follows the standard [Helm chart structure](https://helm.sh/docs/topics/charts/#the-chart-file-structure):

```
charts/<chart-name>/
├── Chart.yaml        # Chart metadata
├── values.yaml       # Default configuration values
├── templates/        # Kubernetes manifest templates
├── charts/           # Sub-chart dependencies
└── README.md         # Chart-specific documentation
```

## Prerequisites

- [Helm](https://helm.sh/docs/intro/install/) v3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured for your target cluster

## Usage

To install a chart from this repository:

```bash
# Clone the repository
git clone https://github.com/KitStream/helms.git

# Install a chart
helm install <release-name> helms/charts/<chart-name>

# Install with custom values
helm install <release-name> helms/charts/<chart-name> -f my-values.yaml
```

## Contributing

We welcome contributions! Please read our [Contributing Guide](CONTRIBUTING.md) before submitting pull requests.

## License

This project is licensed under the Apache License 2.0 — see the [LICENSE](LICENSE) file for details.

Copyright 2026 KitStream

