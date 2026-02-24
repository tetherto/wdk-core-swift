#!/bin/bash
set -e

# =============================================================================
# generate-macos-bundle.sh
#
# Downloads macOS bundle and addon frameworks from a pear-wrk-wdk-jsonrpc
# GitHub release and sets them up for testing.
#
# Usage:
#   ./Scripts/generate-macos-bundle.sh [--tag <version>]
#
# Options:
#   --tag <version>   Release tag to download (default: v1.0.0-beta.2)
# =============================================================================

REPO="claudiovb/pear-wrk-wdk-jsonrpc"
TAG="v1.0.0-beta.2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--tag <release-tag>]"
      exit 0
      ;;
    *)
      echo "Error: Unexpected argument '$1'"
      exit 1
      ;;
  esac
done

echo "🔨 Fetching macOS resources from release $TAG..."
echo "   Repo: $REPO"
echo ""

RESOURCES_DIR="Tests/Resources/macos"
TMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Download release assets
echo "📥 Downloading macos-prebuilds.zip..."
gh release download "$TAG" --repo "$REPO" --pattern "macos-prebuilds.zip" --dir "$TMP_DIR"

echo "📥 Downloading macos-addons.zip..."
gh release download "$TAG" --repo "$REPO" --pattern "macos-addons.zip" --dir "$TMP_DIR"

# Prepare output directory
rm -rf "$RESOURCES_DIR"
mkdir -p "$RESOURCES_DIR/Frameworks"

# Extract bundle
echo "📦 Extracting bundle..."
unzip -q "$TMP_DIR/macos-prebuilds.zip" -d "$RESOURCES_DIR/"

# Extract addon frameworks
echo "📦 Extracting addon frameworks..."
unzip -q "$TMP_DIR/macos-addons.zip" -d "$RESOURCES_DIR/Frameworks/"

# Fix rpaths and re-sign addon frameworks
# install_name_tool invalidates adhoc signatures so we must re-sign after
echo "🔗 Fixing rpaths and re-signing addon frameworks..."
for fw in "$RESOURCES_DIR"/Frameworks/bare-*.framework "$RESOURCES_DIR"/Frameworks/sodium-*.framework; do
  name="$(basename "${fw%.framework}")"
  binary="$fw/$name"
  if [ -f "$binary" ]; then
    install_name_tool -add_rpath '@loader_path/..' "$binary" 2>/dev/null || true
    codesign -s - --force "$binary" 2>/dev/null
  fi
done

ADDON_COUNT=$(ls -d "$RESOURCES_DIR"/Frameworks/*.framework 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "✅ macOS resources downloaded successfully!"
echo "📍 Location: $RESOURCES_DIR/"
echo "   Bundle:     wdk-worklet.macos.bundle"
echo "   Frameworks: $ADDON_COUNT addon frameworks"
echo ""
echo "Run tests with: ./Scripts/test-with-frameworks.sh"
