#!/bin/bash
set -e

echo "Running WdkSwiftCore tests with all frameworks linked..."

cd "$(dirname "$0")/.."

FRAMEWORK_DIR="Tests/Resources/macos/Frameworks"
BUILD_DIR=".build/arm64-apple-macosx/debug"
BAREKIT_FW="Frameworks/BareKit.xcframework/macos-arm64_x86_64"

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

# Copy BareKit.framework to the build directory so the test bundle
# can find it via @rpath (SwiftPM sets @loader_path/../../../ as rpath).
mkdir -p "$BUILD_DIR"
cp -R "$BAREKIT_FW/BareKit.framework" "$BUILD_DIR/" 2>/dev/null || true

# Build and run tests.
# Addon frameworks are NOT linked — they're loaded dynamically by bare
# runtime via dlopen() from the root symlinks above.
swift test \
  -Xcc -F -Xcc "$BAREKIT_FW" \
  -Xlinker -F -Xlinker "$BAREKIT_FW" \
  "$@"
