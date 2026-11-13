#!/bin/bash
set -e

# =============================================================================
# test-with-frameworks.sh
#
# Runs the macOS test suite from a clean checkout in one command:
#
#   1. js/scripts/bootstrap-app.sh builds the worklet bundle and the addon
#      frameworks for js/wdk.config.macos.js and fetches BareKit.xcframework
#      (BareKit 2.x, V8). Nothing is rebuilt or downloaded when it is up to date.
#   2. Scripts/prepare-macos-frameworks.sh fixes the addon rpaths and re-signs them.
#   3. The fixture worklets of Tests/Fixtures/ are packed into bundles with bare-pack.
#   4. `swift test` runs with BareKit linked. Extra arguments are passed to it.
#
# Usage:
#   ./Scripts/test-with-frameworks.sh [swift test arguments]
#
# Environment:
#   WDK_REFRESH=1   Rebuild the bundle and addons even if they are up to date.
# =============================================================================

cd "$(dirname "$0")/.."

BUNDLE="Tests/Resources/macos/wdk-worklet.macos.bundle"
FRAMEWORK_DIR="Tests/Resources/macos/Frameworks"
BAREKIT_DIR="Frameworks"
# Absolute: the Swift Build engine compiles from another working directory, where a
# relative framework search path resolves to nothing.
BAREKIT_FW="$PWD/$BAREKIT_DIR/BareKit.xcframework/macos-arm64_x86_64"

js/scripts/bootstrap-app.sh --platform macos --app-root "$PWD" \
  --config js/wdk.config.macos.js \
  --bundle-out "$BUNDLE" --addons-out "$FRAMEWORK_DIR" --barekit-out "$BAREKIT_DIR"
Scripts/prepare-macos-frameworks.sh --frameworks-dir "$FRAMEWORK_DIR"

# Pack the fixture worklets of Tests/Fixtures/ into bundles. They have no dependencies, so
# the bundles are the same for every host.
FIXTURE_DIR="Tests/Resources/macos/fixtures"
mkdir -p "$FIXTURE_DIR"
for fixture in Tests/Fixtures/*.js; do
  name="$(basename "$fixture" .js)"
  js/node_modules/.bin/bare-pack --out "$FIXTURE_DIR/$name.bundle" "$fixture"
done

echo "Running WdkCore tests with all frameworks linked..."

# Track the temporary framework links owned by this run.
linked_frameworks=()
cleanup() {
  for link in "${linked_frameworks[@]}"; do
    rm -f -- "$link"
  done
  echo "Removed ${#linked_frameworks[@]} temporary framework links"
}
trap cleanup EXIT
# Regenerate root symlinks so dlopen() can resolve addon frameworks from CWD.
# bare runtime calls dlopen("name.framework/name", RTLD_LAZY) with a relative
# path, which resolves from the process CWD (= project root during swift test).
for fw in "$FRAMEWORK_DIR"/bare-*.framework "$FRAMEWORK_DIR"/sodium-*.framework; do
  [ -d "$fw" ] || continue
  link="${fw##*/}"
  ln -sfn "$fw" "$link"
  linked_frameworks+=("$link")
done

# Copy BareKit.framework next to the build products so the test bundle finds it
# via @rpath. The directory depends on the SwiftPM build system, so ask for it.
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$BUILD_DIR"
ditto "$BAREKIT_FW/BareKit.framework" "$BUILD_DIR/BareKit.framework"

# Build and run tests.
# Addon frameworks are NOT linked — they're loaded dynamically by bare
# runtime via dlopen() from the root symlinks above.
swift test \
  -Xcc -F -Xcc "$BAREKIT_FW" \
  -Xlinker -F -Xlinker "$BAREKIT_FW" \
  "$@"
