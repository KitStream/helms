#!/usr/bin/env bash
# upstream-check.sh — Detect new upstream releases and open update PRs.
#
# Reads .upstream-monitor.yaml, queries the GitHub API for latest releases,
# and creates a pull request when a chart is behind upstream.
#
# Required tools: yq (v4+), gh (GitHub CLI), jq, git
#
# Environment variables:
#   GH_TOKEN   — GitHub token (set automatically in GitHub Actions)
#   DRY_RUN    — "true" to skip branch/PR creation (default: "false")
#
# Usage:
#   ./ci/scripts/upstream-check.sh            # normal run
#   DRY_RUN=true ./ci/scripts/upstream-check.sh   # preview only

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG_FILE="${REPO_ROOT}/.upstream-monitor.yaml"
DRY_RUN="${DRY_RUN:-false}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# ── Helpers ───────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
  local missing=()
  for cmd in yq gh jq git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "missing required tools: ${missing[*]}"
  fi
}

# Fetch the latest non-prerelease, non-draft release tag from a GitHub repo.
get_latest_release_tag() {
  local repo="$1"
  gh api "repos/${repo}/releases/latest" --jq '.tag_name' 2>/dev/null || echo ""
}

# Read a YAML field from a file.
read_yaml() {
  local file="$1" path="$2"
  yq eval "$path" "$file"
}

# Write a YAML field in-place.
write_yaml() {
  local file="$1" path="$2" value="$3"
  yq eval -i "${path} = \"${value}\"" "$file"
}

# Bump the patch segment of a semver string (e.g. 0.1.1 → 0.1.2).
bump_patch() {
  local version="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$version"
  echo "${major}.${minor}.$((patch + 1))"
}

# Replace all occurrences of $old with $new in files under $dir.
# Restricted to test YAML files to avoid corrupting CHANGELOG etc.
replace_version_in_tests() {
  local dir="$1" old="$2" new="$3"
  if [[ ! -d "$dir" ]]; then
    return
  fi
  # Use grep + sed to replace only in files that contain the old string.
  local files
  files=$(grep -rl --include='*.yaml' --include='*.yml' "$old" "$dir" 2>/dev/null || true)
  for f in $files; do
    sed -i.bak "s|${old}|${new}|g" "$f"
    rm -f "${f}.bak"
  done
}

# Check whether a PR already exists for this branch.
pr_exists_for_branch() {
  local branch="$1"
  local count
  count=$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo "0")
  [[ "$count" -gt 0 ]]
}

# ── Main ──────────────────────────────────────────────────────────────────

main() {
  check_deps

  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "config file not found: $CONFIG_FILE"
  fi

  local num_charts
  num_charts=$(yq eval '.charts | length' "$CONFIG_FILE")

  for ((i = 0; i < num_charts; i++)); do
    local chart_name chart_rel_path chart_path
    chart_name=$(yq eval ".charts[$i].name" "$CONFIG_FILE")
    chart_rel_path=$(yq eval ".charts[$i].path" "$CONFIG_FILE")
    chart_path="${REPO_ROOT}/${chart_rel_path}"

    log "Chart: $chart_name ($chart_rel_path)"

    if [[ ! -d "$chart_path" ]]; then
      warn "chart directory not found: $chart_path — skipping"
      continue
    fi

    local num_sources
    num_sources=$(yq eval ".charts[$i].sources | length" "$CONFIG_FILE")

    # Collect updates: each entry is "source_name|file|yaml_path|old|new"
    local updates=()

    for ((j = 0; j < num_sources; j++)); do
      local src_name github_repo strip_v
      src_name=$(yq eval ".charts[$i].sources[$j].name" "$CONFIG_FILE")
      github_repo=$(yq eval ".charts[$i].sources[$j].github" "$CONFIG_FILE")
      strip_v=$(yq eval ".charts[$i].sources[$j].strip_v_prefix" "$CONFIG_FILE")

      info "Source: $src_name ($github_repo)"

      local latest_tag
      latest_tag=$(get_latest_release_tag "$github_repo")
      if [[ -z "$latest_tag" ]]; then
        warn "could not fetch latest release for $github_repo — skipping"
        continue
      fi

      local latest_version="$latest_tag"
      if [[ "$strip_v" == "true" ]]; then
        latest_version="${latest_tag#v}"
      fi

      local num_targets
      num_targets=$(yq eval ".charts[$i].sources[$j].targets | length" "$CONFIG_FILE")

      for ((k = 0; k < num_targets; k++)); do
        local target_file yaml_path current_version
        target_file=$(yq eval ".charts[$i].sources[$j].targets[$k].file" "$CONFIG_FILE")
        yaml_path=$(yq eval ".charts[$i].sources[$j].targets[$k].yaml_path" "$CONFIG_FILE")
        current_version=$(read_yaml "${chart_path}/${target_file}" "$yaml_path")

        info "  ${target_file} (${yaml_path}): current=${current_version} latest=${latest_version}"

        if [[ "$current_version" != "$latest_version" ]]; then
          info "  UPDATE: ${current_version} -> ${latest_version}"
          updates+=("${src_name}|${target_file}|${yaml_path}|${current_version}|${latest_version}")
        else
          info "  up to date"
        fi
      done
    done

    # ── No updates needed ──────────────────────────────────────────────
    if [[ ${#updates[@]} -eq 0 ]]; then
      log "No updates needed for $chart_name"
      echo ""
      continue
    fi

    # ── Build branch name and PR description ───────────────────────────
    local branch_parts=()
    local pr_title_parts=()
    local pr_body
    pr_body="## Automated Upstream Version Update"$'\n\n'
    pr_body+="| Component | Old Version | New Version | File |"$'\n'
    pr_body+="| --------- | ----------- | ----------- | ---- |"$'\n'

    for entry in "${updates[@]}"; do
      IFS='|' read -r src file path old new <<< "$entry"
      branch_parts+=("${src}-${new}")
      pr_title_parts+=("${src} ${new}")
      pr_body+="| ${src} | \`${old}\` | \`${new}\` | \`${file}\` |"$'\n'
    done

    local branch_suffix
    branch_suffix=$(IFS='-'; echo "${branch_parts[*]}")
    local branch_name="auto-chart-update/${chart_name}-${branch_suffix}"
    # Truncate branch name if too long (git limit is 255, keep it reasonable).
    if [[ ${#branch_name} -gt 80 ]]; then
      branch_name="auto-chart-update/${chart_name}-$(date +%Y%m%d)"
    fi

    local pr_title joined_parts
    joined_parts=$(printf '%s, ' "${pr_title_parts[@]}")
    joined_parts="${joined_parts%, }"   # strip trailing ", "
    pr_title="chore(${chart_name}): update ${joined_parts}"

    # ── Dry run ────────────────────────────────────────────────────────
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN — would create PR:"
      info "Branch: $branch_name"
      info "Title:  $pr_title"
      echo "$pr_body"
      echo ""
      continue
    fi

    # ── Check for existing PR ──────────────────────────────────────────
    if pr_exists_for_branch "$branch_name"; then
      log "PR already exists for branch $branch_name — skipping"
      echo ""
      continue
    fi

    # ── Apply updates ──────────────────────────────────────────────────
    git checkout -B "$branch_name" "origin/${BASE_BRANCH}"

    for entry in "${updates[@]}"; do
      IFS='|' read -r src file path old new <<< "$entry"
      info "Updating ${file} (${path}): ${old} -> ${new}"
      write_yaml "${chart_path}/${file}" "$path" "$new"
      replace_version_in_tests "${chart_path}/tests" "$old" "$new"
    done

    # Bump chart patch version.
    local old_chart_version new_chart_version
    old_chart_version=$(read_yaml "${chart_path}/Chart.yaml" '.version')
    new_chart_version=$(bump_patch "$old_chart_version")
    write_yaml "${chart_path}/Chart.yaml" '.version' "$new_chart_version"
    info "Chart version: ${old_chart_version} -> ${new_chart_version}"

    pr_body+=$'\n'"Chart version bumped: \`${old_chart_version}\` -> \`${new_chart_version}\`"$'\n'
    pr_body+=$'\n'"---"$'\n'
    pr_body+="This PR was created automatically by the upstream version checker."$'\n'
    pr_body+="CI workflows (lint, unit tests, E2E tests) will run to validate the update."$'\n'

    # ── Commit, push, open PR ──────────────────────────────────────────
    git add "${chart_path}"
    git commit -m "${pr_title}"

    git push -u origin "$branch_name"

    gh pr create \
      --title "$pr_title" \
      --body "$pr_body" \
      --base "$BASE_BRANCH" \
      --head "$branch_name" \
      --label "autorelease"

    log "PR created for $chart_name on branch $branch_name"
    echo ""
  done
}

main "$@"
