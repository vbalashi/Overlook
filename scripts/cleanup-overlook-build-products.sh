#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Overlook.app"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat <<'USAGE'
Usage: scripts/cleanup-overlook-build-products.sh [--dry-run]

Removes local Overlook build products that can appear as duplicate apps in
Spotlight or LaunchServices:
  - build/debug/Overlook.app and build/release/Overlook.app in this checkout
  - Xcode DerivedData Build/Products Overlook.app bundles

This does not reset TCC permissions, preferences, containers, or saved app data.
USAGE
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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
  [[ -d "$app" ]] || return 0

  if [[ -x "$LSREGISTER" ]]; then
    run_quiet "$LSREGISTER" -u "$app" || true
  fi
  run rm -rf "$app"
}

remove_app "$ROOT_DIR/build/debug/$APP_NAME"
remove_app "$ROOT_DIR/build/release/$APP_NAME"

if [[ -d "$DERIVED_DATA_DIR" ]]; then
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    remove_app "$app"
  done < <(find "$DERIVED_DATA_DIR" -path "*/Build/Products/*/$APP_NAME" -type d -prune 2>/dev/null)
fi

if [[ -x "$LSREGISTER" ]]; then
  run_quiet "$LSREGISTER" -r -domain user || true
fi

echo "Overlook build product cleanup finished."
