#!/bin/bash
set -e

echo "Running WdkSwiftCore tests with all frameworks linked..."

cd "$(dirname "$0")/.."

FRAMEWORK_DIR="Tests/Resources/macos/Frameworks"
BUILD_DIR=".build/arm64-apple-macosx/debug"
BAREKIT_FW="Frameworks/BareKit.xcframework/macos-arm64_x86_64"

# Remove only links created by this invocation, if they still point to our addon.
linked_frameworks=()
cleanup() {
  for fw in "${linked_frameworks[@]}"; do
    link="${fw##*/}"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$fw" ]; then
      rm -f -- "$link"
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Regenerate root symlinks so dlopen() can resolve addon frameworks from CWD.
# bare runtime calls dlopen("name.framework/name", RTLD_LAZY) with a relative
# path, which resolves from the process CWD (= project root during swift test).
for fw in "$FRAMEWORK_DIR"/bare-*.framework "$FRAMEWORK_DIR"/sodium-*.framework; do
  [ -d "$fw" ] || continue
  link="${fw##*/}"
  if [ -e "$link" ] || [ -L "$link" ]; then
    echo "Error: refusing to overwrite existing framework path: $link" >&2
    exit 1
  fi
  ln -s "$fw" "$link"
  linked_frameworks+=("$fw")
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
