# Example Seed Configurations

This directory contains example `values.yaml` files demonstrating the structured
database configuration introduced in the NetBird Helm chart.

## Files

| File                                               | Description                          |
| -------------------------------------------------- | ------------------------------------ |
| [`postgresql-values.yaml`](postgresql-values.yaml) | Full example with PostgreSQL backend |
| [`mysql-values.yaml`](mysql-values.yaml)           | Full example with MySQL backend      |

## How It Works

When you set `database.type` to `postgresql` or `mysql`, the chart automatically
adds two Initium init containers to the server pod:

1. **`db-wait`** — Waits for the database to be reachable via TCP with
   exponential backoff (120s timeout). Uses Initium's
   [`wait-for`](https://github.com/KitStream/initium#wait-for) subcommand.

2. **`db-seed`** — Creates the target database if it doesn't exist, using a
   declarative seed spec with `create_if_missing: true`. Uses Initium's
   [`seed`](https://github.com/KitStream/initium#seed) subcommand.

3. **`config-init`** — Renders the config.yaml template, substituting `${VAR}`
   placeholders with actual secret values from Kubernetes Secrets. Uses Initium's
   [`render`](https://github.com/KitStream/initium#render) subcommand.

The DSN is constructed internally by the chart from the structured `database.*`
fields — you never need to build a connection string.

## Providing the Password Secret

Both examples expect a Kubernetes Secret with the database password:

```bash
kubectl create secret generic netbird-db-password \
  --from-literal=password='your-db-password' \
  -n netbird
```

The chart references this secret via `database.passwordSecret.secretName` and
`database.passwordSecret.secretKey`.

## Generated Seed Spec

For reference, here is the seed spec the chart generates for PostgreSQL
(rendered into the `seed.yaml` key of the server ConfigMap):

```yaml
database:
  driver: postgres
  host: postgres.database.svc.cluster.local
  port: 5432
  user: netbird
  password: "{{ env.DB_PASSWORD }}"
  name: netbird
  options:
    sslmode: disable
phases:
  - name: create-database
    database: netbird
    create_if_missing: true
```

The `{{ env.DB_PASSWORD }}` is a MiniJinja template variable that Initium
resolves at runtime from the `DB_PASSWORD` environment variable (injected via
`secretKeyRef` from your password Secret). Initium v2's structured connection
config builds the connection internally, so passwords with special characters
work without any URL encoding.
