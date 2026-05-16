#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <semver> [build]

Examples:
  scripts/set-version.sh 1.1.0
  scripts/set-version.sh 1.1.0 42

Updates Overlook's MARKETING_VERSION and CURRENT_PROJECT_VERSION in the
Xcode project. If build is omitted, the current build number is incremented.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

VERSION="${1:-}"
BUILD="${2:-}"

if [[ -z "$VERSION" ]]; then
  usage >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "error: version must be SemVer-like, for example 1.1.0" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

PROJECT_FILE="Overlook.xcodeproj/project.pbxproj"

if [[ -z "$BUILD" ]]; then
  CURRENT_BUILD="$(awk -F' = ' '/CURRENT_PROJECT_VERSION =/ { gsub(/;/, "", $2); print $2; exit }' "$PROJECT_FILE")"
  if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    BUILD="$((CURRENT_BUILD + 1))"
  else
    echo "error: current build number is not numeric; pass build explicitly" >&2
    exit 1
  fi
fi

if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: build must be a positive integer" >&2
  exit 1
fi

perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$PROJECT_FILE"

echo "Set Overlook version to v$VERSION (build $BUILD)."
echo
echo "Recommended release commit and tag:"
echo "  git add $PROJECT_FILE README.md"
echo "  git commit -m \"Release v$VERSION (build $BUILD)\""
echo "  git tag -a v$VERSION -m \"Overlook v$VERSION (build $BUILD)\""
