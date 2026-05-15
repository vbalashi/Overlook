#!/usr/bin/env bash
set -euo pipefail

CONFIG="Debug"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-c debug|release] [-- xcodebuild args...]

Options:
  -c, --config   Build configuration: debug (default) or release
  -h, --help     Show this help

Any arguments after -- are passed through to xcodebuild.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      shift
      [[ $# -gt 0 ]] || { echo "error: --config requires a value" >&2; exit 1; }
      case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        debug)   CONFIG="Debug" ;;
        release) CONFIG="Release" ;;
        *) echo "error: config must be 'debug' or 'release'" >&2; exit 1 ;;
      esac
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")"

DEST_DIR="build/$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')"
APP_NAME="Overlook.app"

run_xcodebuild() {
  xcodebuild \
    -project Overlook.xcodeproj \
    -scheme Overlook \
    -configuration "$CONFIG" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    ENABLE_DEBUG_DYLIB=NO \
    "$@"
}

cleanup_derived_data_apps() {
  local app
  local derived_data="$HOME/Library/Developer/Xcode/DerivedData"

  [[ -d "$derived_data" ]] || return 0

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ -x "$LSREGISTER" ]]; then
      "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    fi
    rm -rf "$app"
  done < <(find "$derived_data" -path "*/Build/Products/*/$APP_NAME" -type d -prune 2>/dev/null)
}

echo "Building Overlook ($CONFIG)..."
run_xcodebuild build "$@"

BUILT_PRODUCTS_DIR=$(run_xcodebuild \
  -showBuildSettings build "$@" 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR =/ {print $2; exit}')

FULL_PRODUCT_NAME=$(run_xcodebuild \
  -showBuildSettings build "$@" 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME =/ {print $2; exit}')

APP_SRC="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: built app not found at $APP_SRC" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/$FULL_PRODUCT_NAME"
cp -R "$APP_SRC" "$DEST_DIR/"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  if [[ "$APP_SRC" != "$PWD/$DEST_DIR/$FULL_PRODUCT_NAME" ]]; then
    "$LSREGISTER" -u "$APP_SRC" >/dev/null 2>&1 || true
  fi
  "$LSREGISTER" -f -R -trusted "$DEST_DIR/$FULL_PRODUCT_NAME"
fi

cleanup_derived_data_apps

echo "Copied $FULL_PRODUCT_NAME -> $DEST_DIR/"
