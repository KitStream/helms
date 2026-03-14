#!/usr/bin/env bash
#
# Compatibility matrix: test the current chart against recent NetBird server versions.
#
# Produces/updates docs/compatibility.md with a 2D table (chart minors × server minors).
# Each run fills the current chart version's row; older rows are preserved.
#
# Usage:
#   ci/scripts/compat-matrix.sh
#
# Requires: helm, kubectl, gh, yq (or sed/grep for Chart.yaml parsing)
#
set -uo pipefail

CHART="charts/netbird"
COMPAT_FILE="docs/compatibility.md"
NUM_MINORS=5

log()  { echo "==> $*"; }

# ── Read current chart version + appVersion ──────────────────────────
CHART_VERSION=$(grep '^version:' "$CHART/Chart.yaml" | awk '{print $2}')
APP_VERSION=$(grep '^appVersion:' "$CHART/Chart.yaml" | awk '{print $2}' | tr -d '"')
CHART_MINOR="${CHART_VERSION%.*}"  # e.g. "0.2" from "0.2.1"

log "Chart version: $CHART_VERSION (minor: $CHART_MINOR)"
log "App version (current): $APP_VERSION"

# ── Version discovery via GitHub API ─────────────────────────────────
log "Fetching NetBird releases from GitHub..."
ALL_VERSIONS=$(gh api repos/netbirdio/netbird/releases --paginate \
  -q '.[] | select(.prerelease == false) | .tag_name' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed 's/^v//' \
  | sort -t. -k1,1n -k2,2n -k3,3n)

if [ -z "$ALL_VERSIONS" ]; then
  echo "ERROR: Could not fetch releases from GitHub" >&2
  exit 0
fi

# Current appVersion's minor number (e.g. 66 from 0.66.4)
CURRENT_MINOR=$(echo "$APP_VERSION" | cut -d. -f2)

# Group by major.minor, pick highest patch per minor, filter to versions
# with minor <= current, then take the last NUM_MINORS entries.
SERVER_VERSIONS=()
while IFS= read -r ver; do
  SERVER_VERSIONS+=("$ver")
done < <(echo "$ALL_VERSIONS" \
  | awk -F. -v max_minor="$CURRENT_MINOR" '
    $2 <= max_minor {
      key = $1 "." $2
      if (!(key in best) || ($3+0) > (best_patch[key]+0)) {
        best[key] = $0
        best_patch[key] = $3+0
      }
    }
    END {
      for (key in best) print best[key]
    }' \
  | sort -t. -k1,1n -k2,2n \
  | tail -n "$NUM_MINORS" \
  | sort -t. -k1,1rn -k2,2rn)  # newest first

log "Server versions to test: ${SERVER_VERSIONS[*]}"

# ── resolve_values: same pattern as e2e.sh ───────────────────────────
resolve_values() {
  local src="$1" ns="$2"
  local tmp
  tmp=$(mktemp)
  sed "s/netbird-e2e/$ns/g" "$src" > "$tmp"
  echo "$tmp"
}

# ── Cleanup trap ─────────────────────────────────────────────────────
cleanup() {
  log "Cleaning up compat-matrix namespaces..."
  for ns in $(kubectl get ns -o name 2>/dev/null | grep 'namespace/nb-compat-' | sed 's|namespace/||'); do
    helm uninstall "compat-test" -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "$ns" --ignore-not-found 2>/dev/null || true
  done
}
trap cleanup EXIT

# ── Check if a Docker Hub image tag exists ───────────────────────────
image_tag_exists() {
  local repo="$1" tag="$2"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}/")
  [ "$status" = "200" ]
}

# ── Per-version test loop ────────────────────────────────────────────
declare -A RESULTS  # key=server_version, value=pass|fail:reason|n/a:reason

# Read server image repository from values.yaml
SERVER_IMAGE_REPO=$(grep -A2 '^server:' "$CHART/values.yaml" | grep -v '^server:' | head -n5 || true)
SERVER_IMAGE_REPO=$(awk '/^server:/,0' "$CHART/values.yaml" | grep 'repository:' | head -1 | awk '{print $2}')
if [ -z "$SERVER_IMAGE_REPO" ]; then
  SERVER_IMAGE_REPO="netbirdio/netbird-server"
fi
log "Server image repository: $SERVER_IMAGE_REPO"

for VER in "${SERVER_VERSIONS[@]}"; do
  MAJOR=$(echo "$VER" | cut -d. -f1)
  MINOR=$(echo "$VER" | cut -d. -f2)
  NAMESPACE="nb-compat-${MAJOR}-${MINOR}"
  RELEASE="compat-test"

  log "Testing server version $VER in namespace $NAMESPACE..."

  # Check if the Docker image tag exists before deploying
  if ! image_tag_exists "$SERVER_IMAGE_REPO" "$VER"; then
    log "Server $VER: N/A (image $SERVER_IMAGE_REPO:$VER not found on Docker Hub)"
    RESULTS["$VER"]="n/a:image-not-found"
    continue
  fi

  # Wait for any previous namespace deletion
  for _i in $(seq 1 60); do
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
      break
    fi
    if [ "$_i" -eq 60 ]; then
      log "Timed out waiting for namespace $NAMESPACE to be deleted"
      RESULTS["$VER"]="fail:namespace-timeout"
      continue 2
    fi
    sleep 2
  done

  # Create namespace
  if ! kubectl create namespace "$NAMESPACE" 2>/dev/null; then
    RESULTS["$VER"]="fail:namespace-create"
    continue
  fi

  # Resolve values
  VALUES_FILE=$(resolve_values "$CHART/ci/e2e-values.yaml" "$NAMESPACE")

  # Helm install with server image tag override
  if ! helm install "$RELEASE" "$CHART" \
    -n "$NAMESPACE" \
    -f "$VALUES_FILE" \
    --set fullnameOverride="$RELEASE" \
    --set server.image.tag="$VER" \
    --set server.persistentVolume.enabled=true \
    --timeout 5m 2>&1; then
    log "Helm install failed for $VER"
    RESULTS["$VER"]="fail:helm-install"
    helm uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    rm -f "$VALUES_FILE"
    continue
  fi

  # Verify rollout
  ROLLOUT_OK=true
  if ! kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-server --timeout=300s 2>&1; then
    ROLLOUT_OK=false
  fi
  if ! kubectl -n "$NAMESPACE" rollout status deployment/"$RELEASE"-dashboard --timeout=120s 2>&1; then
    ROLLOUT_OK=false
  fi

  if [ "$ROLLOUT_OK" = false ]; then
    log "Rollout failed for $VER"
    kubectl -n "$NAMESPACE" get pods -o wide 2>/dev/null || true
    RESULTS["$VER"]="fail:rollout"
    helm uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    rm -f "$VALUES_FILE"
    continue
  fi

  # Run helm test
  if helm test "$RELEASE" -n "$NAMESPACE" --timeout 2m 2>&1; then
    log "Server $VER: PASS"
    RESULTS["$VER"]="pass"
  else
    log "Server $VER: FAIL (helm test)"
    RESULTS["$VER"]="fail:helm-test"
  fi

  # Cleanup
  helm uninstall "$RELEASE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  rm -f "$VALUES_FILE"
done

# ── Generate/update compatibility matrix ─────────────────────────────
log "Generating compatibility matrix..."

# Parse existing rows from docs/compatibility.md (if it exists)
declare -A EXISTING  # key="chart_minor|server_minor" value="emoji"
EXISTING_CHART_MINORS=()

if [ -f "$COMPAT_FILE" ]; then
  while IFS= read -r line; do
    # Match table rows like "| 0.1            | :white_check_mark: | ... |"
    # Skip header rows (containing "Chart" or "---")
    if echo "$line" | grep -qE '^\|[[:space:]]+[0-9]+\.[0-9]+'; then
      chart_m=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
      # Skip if this is the current chart minor (we'll rebuild it)
      if [ "$chart_m" = "$CHART_MINOR" ]; then
        continue
      fi

      # Check if we already have this chart minor
      found=false
      for cm in "${EXISTING_CHART_MINORS[@]+"${EXISTING_CHART_MINORS[@]}"}"; do
        if [ "$cm" = "$chart_m" ]; then found=true; break; fi
      done
      if [ "$found" = false ]; then
        EXISTING_CHART_MINORS+=("$chart_m")
      fi

      # Extract header columns from the file to map positions to server minors
      HEADER_LINE=$(grep -E '^\| Chart.*Server' "$COMPAT_FILE" || true)
      if [ -n "$HEADER_LINE" ]; then
        # Parse server minor versions from header
        HEADER_COLS=()
        while IFS= read -r col; do
          col=$(echo "$col" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          if [ -n "$col" ] && ! echo "$col" | grep -q 'Chart'; then
            HEADER_COLS+=("$col")
          fi
        done < <(echo "$HEADER_LINE" | tr '|' '\n' | tail -n +3)

        # Extract values from this row
        col_idx=0
        while IFS= read -r val; do
          val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          if [ "$col_idx" -gt 0 ] && [ "$col_idx" -le "${#HEADER_COLS[@]}" ]; then
            sv="${HEADER_COLS[$((col_idx-1))]}"
            if [ -n "$val" ] && [ -n "$sv" ]; then
              EXISTING["${chart_m}|${sv}"]="$val"
            fi
          fi
          col_idx=$((col_idx + 1))
        done < <(echo "$line" | tr '|' '\n')
      fi
    fi
  done < "$COMPAT_FILE"
fi

# Collect all server minors: from current run + existing data
ALL_SERVER_MINORS=()
for VER in "${SERVER_VERSIONS[@]}"; do
  sm="$(echo "$VER" | cut -d. -f1).$(echo "$VER" | cut -d. -f2)"
  found=false
  for m in "${ALL_SERVER_MINORS[@]+"${ALL_SERVER_MINORS[@]}"}"; do
    if [ "$m" = "$sm" ]; then found=true; break; fi
  done
  if [ "$found" = false ]; then
    ALL_SERVER_MINORS+=("$sm")
  fi
done

for key in "${!EXISTING[@]}"; do
  sm="${key#*|}"
  found=false
  for m in "${ALL_SERVER_MINORS[@]+"${ALL_SERVER_MINORS[@]}"}"; do
    if [ "$m" = "$sm" ]; then found=true; break; fi
  done
  if [ "$found" = false ]; then
    ALL_SERVER_MINORS+=("$sm")
  fi
done

# Sort server minors descending (newest first)
IFS=$'\n' ALL_SERVER_MINORS=($(printf '%s\n' "${ALL_SERVER_MINORS[@]}" | sort -t. -k1,1rn -k2,2rn)); unset IFS

# Collect all chart minors (current + existing), sorted descending
ALL_CHART_MINORS=("$CHART_MINOR")
for cm in "${EXISTING_CHART_MINORS[@]+"${EXISTING_CHART_MINORS[@]}"}"; do
  found=false
  for m in "${ALL_CHART_MINORS[@]}"; do
    if [ "$m" = "$cm" ]; then found=true; break; fi
  done
  if [ "$found" = false ]; then
    ALL_CHART_MINORS+=("$cm")
  fi
done
IFS=$'\n' ALL_CHART_MINORS=($(printf '%s\n' "${ALL_CHART_MINORS[@]}" | sort -t. -k1,1rn -k2,2rn)); unset IFS

# Build current chart row results
for VER in "${SERVER_VERSIONS[@]}"; do
  sm="$(echo "$VER" | cut -d. -f1).$(echo "$VER" | cut -d. -f2)"
  result="${RESULTS[$VER]:-}"
  if [ "$result" = "pass" ]; then
    EXISTING["${CHART_MINOR}|${sm}"]=":white_check_mark:"
  elif echo "$result" | grep -q '^n/a'; then
    EXISTING["${CHART_MINOR}|${sm}"]=":heavy_minus_sign:"
  elif [ -n "$result" ]; then
    EXISTING["${CHART_MINOR}|${sm}"]=":x:"
  fi
done

# Write the markdown file
mkdir -p "$(dirname "$COMPAT_FILE")"

{
  echo "# NetBird Helm Chart — Compatibility Matrix"
  echo ""
  echo "> Auto-generated by \`make compat-matrix\` — do not edit manually."
  echo ">"
  echo "> Last updated: $(date +%Y-%m-%d)"
  echo ""

  # Header row
  printf "| Chart ╲ Server |"
  for sm in "${ALL_SERVER_MINORS[@]}"; do
    printf " %s |" "$sm"
  done
  echo ""

  # Separator row
  printf "|----------------|"
  for _ in "${ALL_SERVER_MINORS[@]}"; do
    printf '%s' "------|"
  done
  echo ""

  # Data rows
  for cm in "${ALL_CHART_MINORS[@]}"; do
    printf "| %-14s |" "$cm"
    for sm in "${ALL_SERVER_MINORS[@]}"; do
      cell="${EXISTING["${cm}|${sm}"]:-—}"
      printf '%s' " $cell |"
    done
    echo ""
  done
} > "$COMPAT_FILE"

log "Compatibility matrix written to $COMPAT_FILE"

# ── Print summary ───────────────────────────────────────────────────
echo ""
echo "=== Compatibility Matrix Summary ==="
echo "Chart version: $CHART_VERSION (minor: $CHART_MINOR)"
echo ""
for VER in "${SERVER_VERSIONS[@]}"; do
  result="${RESULTS[$VER]:-untested}"
  if [ "$result" = "pass" ]; then
    echo "  Server $VER: PASS"
  elif echo "$result" | grep -q '^n/a'; then
    echo "  Server $VER: N/A ($result)"
  else
    echo "  Server $VER: FAIL ($result)"
  fi
done
echo ""
cat "$COMPAT_FILE"

exit 0
