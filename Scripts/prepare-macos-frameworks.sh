#!/bin/bash
set -e

# =============================================================================
# prepare-macos-frameworks.sh
#
# Prepares the macOS addon frameworks used by the test suite so the Bare
# runtime can load them:
#
#   1. Adds the rpaths sibling addons need to find each other. Addons dlopen
#      one another (e.g. bare-crypto -> bare-buffer) relative to their own
#      binary. Flat frameworks need `@loader_path/..`; the symlinked
#      Versions/A layout that bare-link >= 3.3 emits keeps the real binary in
#      Versions/A/, so it also needs `@loader_path/../../..`.
#   2. Re-signs each framework ad hoc. install_name_tool invalidates the
#      existing signature, and frameworks copied or dragged out of the bundler
#      output lose theirs anyway, which makes the linker refuse them.
#   3. Strips the com.apple.quarantine attribute Gatekeeper attaches to
#      BareKit.xcframework when it is downloaded from GitHub releases. The
#      addon frameworks are generated locally by the bundler and never carry it.
#
# Scripts/test-with-frameworks.sh calls this after js/scripts/bootstrap-app.sh has
# built the frameworks into Tests/Resources/macos/Frameworks/. Run it by hand only
# for frameworks you staged yourself.
#
# Usage (from anywhere; paths are resolved relative to the repo root):
#   ./Scripts/prepare-macos-frameworks.sh [--frameworks-dir <path>]
#
# Options:
#   --frameworks-dir <path>   Directory containing the *.framework bundles
#                             (default: Tests/Resources/macos/Frameworks)
#
# Called with no arguments, the option loop below is skipped entirely and the
# defaults apply.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

FRAMEWORKS_DIR="Tests/Resources/macos/Frameworks"
BAREKIT_XCFRAMEWORK="Frameworks/BareKit.xcframework"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frameworks-dir)
      FRAMEWORKS_DIR="$2"
      shift 2   # drop the flag and its value from $@ so the loop sees the next argument
      ;;
    --help|-h)
      sed -n '/^# Usage/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    *)
      echo "Error: Unexpected argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$FRAMEWORKS_DIR" ]; then
  echo "Error: '$FRAMEWORKS_DIR' not found." >&2
  echo "Run ./Scripts/test-with-frameworks.sh, which builds the macOS addons there first." >&2
  exit 1
fi

echo "🔗 Fixing rpaths and re-signing frameworks in $FRAMEWORKS_DIR ..."

count=0
for fw in "$FRAMEWORKS_DIR"/*.framework; do
  [ -d "$fw" ] || continue
  name="$(basename "${fw%.framework}")"
  binary="$fw/$name"
  if [ ! -f "$binary" ]; then
    echo "   ⚠️  $name: no binary at $binary, skipping"
    continue
  fi
  # -add_rpath fails if the rpath is already present; that is fine.
  install_name_tool -add_rpath '@loader_path/..' "$binary" 2>/dev/null || true
  install_name_tool -add_rpath '@loader_path/../../..' "$binary" 2>/dev/null || true
  codesign -s - --force "$binary" 2>/dev/null
  echo "   ✓ $name"
  count=$((count + 1))
done

if [ -d "$BAREKIT_XCFRAMEWORK" ]; then
  xattr -dr com.apple.quarantine "$BAREKIT_XCFRAMEWORK" 2>/dev/null || true
  echo "🧹 Removed quarantine attribute from $BAREKIT_XCFRAMEWORK"
fi

echo "✅ Prepared $count frameworks in $FRAMEWORKS_DIR"
