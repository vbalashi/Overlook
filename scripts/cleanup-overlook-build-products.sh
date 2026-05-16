#!/usr/bin/env bash
set -euo pipefail

APP_NAMES=("Overlook.app" "Overlook Debug.app")
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat <<'USAGE'
Usage: scripts/cleanup-overlook-build-products.sh [--dry-run] [--keep APP_PATH] [--check]

Removes local Overlook build products that can appear as duplicate apps in
Spotlight or LaunchServices:
  - build/debug and build/release Overlook app bundles in this checkout
  - Xcode DerivedData Build/Products Overlook app bundles

Use --keep APP_PATH after a build to preserve the canonical app bundle while
removing every other local build product. Use --check to fail if any duplicate
build product exists besides the kept app.

This does not reset TCC permissions, preferences, containers, or saved app data.
USAGE
}

DRY_RUN=0
CHECK_ONLY=0
KEEP_APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --check)
      CHECK_ONLY=1
      ;;
    --keep)
      shift
      [[ $# -gt 0 ]] || { echo "error: --keep requires an app path" >&2; exit 64; }
      KEEP_APP="$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@"
  fi
}

run_quiet() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$@" >/dev/null 2>&1
  fi
}

remove_app() {
  local app="$1"
  local resolved_app
  [[ -d "$app" ]] || return 0

  resolved_app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  if [[ -n "$KEEP_APP" && "$resolved_app" == "$KEEP_APP" ]]; then
    echo "Keeping canonical build product: $resolved_app"
    return 0
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "Duplicate Overlook build product found: $resolved_app" >&2
    return 2
  fi

  if [[ -x "$LSREGISTER" ]]; then
    run_quiet "$LSREGISTER" -u "$resolved_app" || true
  fi
  run rm -rf "$resolved_app"
}

FAILED=0

for app_name in "${APP_NAMES[@]}"; do
  remove_app "$ROOT_DIR/build/debug/$app_name" || FAILED=1
  remove_app "$ROOT_DIR/build/release/$app_name" || FAILED=1
done

if [[ -d "$DERIVED_DATA_DIR" ]]; then
  for app_name in "${APP_NAMES[@]}"; do
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      remove_app "$app" || FAILED=1
    done < <(find "$DERIVED_DATA_DIR" -path "*/Build/Products/*/$app_name" -type d -prune 2>/dev/null)
  done
fi

if [[ "$FAILED" -ne 0 ]]; then
  exit 1
fi

if [[ -x "$LSREGISTER" ]]; then
  run_quiet "$LSREGISTER" -r -domain user || true
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "No duplicate Overlook build products found."
else
  echo "Overlook build product cleanup finished."
fi
