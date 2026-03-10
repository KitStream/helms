#!/usr/bin/env bash
# upstream-check.sh — Detect new upstream releases and open GitHub issues.
#
# Reads .upstream-monitor.yaml, queries the GitHub API for latest releases,
# and creates a GitHub issue when a chart is behind upstream.
#
# Required tools: yq (v4+), gh (GitHub CLI), jq
#
# Environment variables:
#   GH_TOKEN   — GitHub token (set automatically in GitHub Actions)
#   DRY_RUN    — "true" to skip issue creation (default: "false")
#
# Usage:
#   ./ci/scripts/upstream-check.sh            # normal run
#   DRY_RUN=true ./ci/scripts/upstream-check.sh   # preview only

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG_FILE="${REPO_ROOT}/.upstream-monitor.yaml"
DRY_RUN="${DRY_RUN:-false}"

# ── Helpers ───────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
  local missing=()
  for cmd in yq gh jq; do
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

# Fetch the URL of the latest release page.
get_latest_release_url() {
  local repo="$1"
  gh api "repos/${repo}/releases/latest" --jq '.html_url' 2>/dev/null || echo ""
}

# Read a YAML field from a file.
read_yaml() {
  local file="$1" path="$2"
  yq eval "$path" "$file"
}

# Check whether an open issue already exists with the given title.
issue_exists_with_title() {
  local title="$1"
  local count
  count=$(gh issue list --state open --search "$title" --json number,title \
    --jq "[.[] | select(.title == \"$title\")] | length" 2>/dev/null || echo "0")
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

    # Collect updates: each entry is "source_name|github_repo|file|yaml_path|old|new"
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
          info "  UPDATE AVAILABLE: ${current_version} -> ${latest_version}"
          updates+=("${src_name}|${github_repo}|${target_file}|${yaml_path}|${current_version}|${latest_version}")
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

    # ── Build issue title and body ─────────────────────────────────────
    local title_parts=()
    local issue_body
    issue_body="## Upstream Version Update Available"$'\n\n'
    issue_body+="The following upstream component(s) for the **${chart_name}** chart have new releases:"$'\n\n'
    issue_body+="| Component | Current Version | Latest Version | File | Field |"$'\n'
    issue_body+="| --------- | --------------- | -------------- | ---- | ----- |"$'\n'

    for entry in "${updates[@]}"; do
      IFS='|' read -r src repo file path old new <<< "$entry"
      title_parts+=("${src} ${old} → ${new}")
      local release_url
      release_url=$(get_latest_release_url "$repo")
      if [[ -n "$release_url" ]]; then
        issue_body+="| ${src} | \`${old}\` | [\`${new}\`](${release_url}) | \`${file}\` | \`${path}\` |"$'\n'
      else
        issue_body+="| ${src} | \`${old}\` | \`${new}\` | \`${file}\` | \`${path}\` |"$'\n'
      fi
    done

    issue_body+=$'\n'"### What needs to be done"$'\n\n'
    issue_body+="1. Update the version references listed above."$'\n'
    issue_body+="2. Update any hardcoded version strings in test assertions (\`charts/${chart_name}/tests/\`)."$'\n'
    issue_body+="3. Bump the chart version in \`Chart.yaml\`."$'\n'
    issue_body+="4. Review the upstream release notes for breaking changes."$'\n'
    issue_body+="5. Run \`make test\` to verify lint and unit tests pass."$'\n'
    issue_body+=$'\n'"---"$'\n'
    issue_body+="*This issue was created automatically by the upstream version checker.*"$'\n'

    local joined_parts
    joined_parts=$(printf '%s, ' "${title_parts[@]}")
    joined_parts="${joined_parts%, }"
    local issue_title="chore(${chart_name}): upstream update available — ${joined_parts}"

    # ── Dry run ────────────────────────────────────────────────────────
    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY RUN — would create issue:"
      info "Title: $issue_title"
      echo "$issue_body"
      echo ""
      continue
    fi

    # ── Check for existing issue ───────────────────────────────────────
    if issue_exists_with_title "$issue_title"; then
      log "Issue already exists with title: $issue_title — skipping"
      echo ""
      continue
    fi

    # ── Ensure label exists ─────────────────────────────────────────────
    if ! gh label list --search "autorelease" --json name --jq '.[].name' 2>/dev/null | grep -qx "autorelease"; then
      gh label create autorelease --description "Automated upstream version update" --color "0e8a16" 2>/dev/null || true
    fi

    # ── Create issue ───────────────────────────────────────────────────
    gh issue create \
      --title "$issue_title" \
      --body "$issue_body" \
      --label "autorelease"

    log "Issue created for $chart_name"
    echo ""
  done
}

main "$@"
