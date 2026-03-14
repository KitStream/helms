---
description: Prepare a chart release — bump version, update changelog, commit, and create PR
user_invocable: true
argument: Optional chart name (e.g. "netbird"). If omitted, auto-detect from git history.
---

You are preparing a Helm chart release. Follow these steps precisely.

## 1. Determine which chart(s) to release

If the user provided an argument "$ARGUMENTS", use that as the chart name.

Otherwise, detect which charts have unreleased changes:

- For each directory under `charts/`, find the latest git tag matching `<chart-name>-*`
- Run `git log <latest-tag>..origin/main -- charts/<chart-name>/` to see if there are commits since the last release
- If there are commits, that chart needs a release
- If no charts need releasing, inform the user and stop

## 2. Determine the version bump

For each chart that needs releasing, analyze the commits since the last release tag:

- `git log --oneline <latest-tag>..origin/main -- charts/<chart-name>/`

Apply conventional commit rules to determine the bump:

- **major**: any commit message contains `BREAKING CHANGE` or has a `!` after the type (e.g. `feat!:`, `fix!:`)
- **minor**: any commit message starts with `feat:` or `feat(<scope>):`
- **patch**: all other changes (`fix:`, `chore:`, `docs:`, `refactor:`, etc.)

Use the highest applicable bump. Parse the current version from `charts/<chart-name>/Chart.yaml`.

Present the proposed version bump to the user (current version -> new version) along with the commit list, and ask for confirmation before proceeding. The user may override the bump level.

## 3. Update Chart.yaml

- Bump the `version:` field to the new version
- Update the `artifacthub.io/changes` annotation with changelog entries derived from the commits since the last release. Each entry should have a `kind` (added/changed/fixed/security/deprecated/removed) mapped from the conventional commit type:
  - `feat` -> `added`
  - `fix` -> `fixed`
  - `chore`, `refactor`, `perf`, `docs`, `style`, `build`, `ci` -> `changed`
  - `security` -> `security`
  - `deprecate` -> `deprecated`
  - `remove` -> `removed`
- Use the commit subject (without the conventional commit prefix) as the description

## 4. Update compatibility matrix (minor version bumps only)

If the version bump includes a **minor** (or major) version change, run:

```
make compat-matrix
```

This tests the chart against the last 5 NetBird server minor versions and updates `charts/netbird/docs/compatibility.md` with a new row for the new chart minor. The updated file will be included in the release commit.

Skip this step for patch-only bumps — the existing row already covers the current chart minor.

## 5. Run tests

Run the full test suite for the chart:

```
make test
```

If tests fail, fix the issue before continuing.

## 6. Commit and create PR

- Create a new branch from origin/main named `release/<chart-name>-<new-version>`
- Commit with message: `chore: prepare <chart-name> v<new-version> release`
- Present the summary of changes to the user and let them decide when to create the PR (per CLAUDE.md: do NOT create a PR automatically from Claude Code)
