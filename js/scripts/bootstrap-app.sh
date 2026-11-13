#!/bin/bash
set -euo pipefail

# =============================================================================
# bootstrap-app.sh
#
# Builds everything an app needs next to the WdkCore Swift package and
# places it in the app:
#
#   1. installs the pinned JavaScript toolchain of this directory,
#   2. builds the worklet bundle and links the native addons for the app's
#      wdk.config.js (wdk-worklet-bundler, JSON-RPC transport),
#   3. moves the bundle, the addon frameworks and (iOS) addons.yml into the app,
#   4. fetches BareKit.xcframework (BareKit 2.x) into the app. This is checked first, so an
#      unsupported BareKit release or framework stops the run before anything is built.
#
# It is the single entry point for a consumer app (called from the XcodeGen
# preGenCommand, see the README) and for this repository's macOS tests (called
# by Scripts/test-with-frameworks.sh).
#
# Usage:
#   bootstrap-app.sh --platform <ios|macos> --app-root <dir> [options]
#
# Options:
#   --platform <ios|macos>   Platform to build for.
#   --app-root <dir>         Root of the app. Relative paths below resolve against it.
#   --config <file>          Worklet configuration (default: wdk.config.js).
#   --bundle-out <file>      Destination of the worklet bundle (default:
#                            wdk-worklet.mobile.bundle on iOS, wdk-worklet.macos.bundle on macOS).
#   --addons-out <dir>       Destination of the addon frameworks (default: addons).
#                            On iOS it also receives addons.yml.
#   --barekit-out <dir>      Destination of BareKit.xcframework (default: frameworks).
#   --engine <v8|javascriptcore>
#                            BareKit engine (default: v8). JavaScriptCore is
#                            discouraged, see js/README.md.
#   --barekit-tag <v2.x.y>   BareKit 2.x release (default: the one pinned in fetch-barekit.sh).
#   --core-ref <ref>         Branch, tag, version or commit this wdk-core-swift checkout must be
#                            at. Meant for the clone an app's build keeps for itself: the
#                            checkout is switched to <ref> before anything else runs.
#
# Environment:
#   WDK_REFRESH=1   Skip the up-to-date check and rebuild everything.
#
# The worklet configuration:
#   - is copied into this directory, because the bundler resolves wallet
#     packages next to the configuration file;
#   - must not have an `output` section: the bundler writes to its default
#     locations here and this script moves the results to the destinations above;
#   - may name wallet packages that are not in package.json: they are installed
#     on the fly (latest version) by the bundler's --install.
#
# Repeat runs are instant and work offline: nothing is rebuilt while the
# configuration, the pinned toolchain, the engine, the BareKit release and the
# destinations are unchanged and the outputs are still in place.
#
# Exit status: 0 on success, 1 on any error (message on stderr).
# =============================================================================

JS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly JS_DIR
CORE_DIR="$(dirname "$JS_DIR")"
readonly CORE_DIR
readonly BUNDLER="$JS_DIR/node_modules/.bin/wdk-worklet-bundler"
readonly FETCH_BAREKIT="$JS_DIR/scripts/fetch-barekit.sh"
readonly CACHE_DIR="$JS_DIR/.wdk-cache"
readonly CORE_REF_FILE="$CORE_DIR/.wdk-core-ref"
readonly COPIED_CONFIG_NAME="wdk.config.js"
# Name of the file, kept in --addons-out, that lists what this script put there.
readonly ADDONS_MANIFEST=".wdk-addons"
# Where the bundler writes the bundle when the configuration has no `output` section.
readonly BUNDLER_BUNDLE_CANDIDATES=".wdk-bundle/wdk-worklet.bundle .wdk-bundle/wdk-worklet.bundle.js"
readonly BUILD_LOCK="$CACHE_DIR/build.lock"
# Longest a run waits for another bootstrap that is building in this directory.
readonly BUILD_LOCK_TIMEOUT_SECONDS=900

die() {
  echo "bootstrap-app: $*" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^# The worklet configuration:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Prints $1 as an absolute path, resolving a relative one against the app root.
resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s\n' "$APP_ROOT/$1" ;;
  esac
}

# Removes the directories the bundler writes to by default inside this directory.
clean_bundler_outputs() {
  rm -rf "${JS_DIR:?}/.wdk" "${JS_DIR:?}/.wdk-bundle" "${JS_DIR:?}/ios-addons" "${JS_DIR:?}/mac-addons"
}

# Waits until no other run is building in this directory, then claims it. Runs share
# node_modules, the copied configuration and the bundler's output directories, so two at once
# (two apps on one checkout, say) would corrupt each other.
acquire_build_lock() {
  local waited=0 holder
  mkdir -p "$CACHE_DIR"
  while ! mkdir "$BUILD_LOCK" 2>/dev/null; do
    holder="$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "${BUILD_LOCK:?}" # left behind by a run that was killed
      continue
    fi
    if [ "$waited" -ge "$BUILD_LOCK_TIMEOUT_SECONDS" ]; then
      die "another bootstrap has been building in $JS_DIR for over $BUILD_LOCK_TIMEOUT_SECONDS seconds.
If none is running, delete $BUILD_LOCK and run again."
    fi
    if [ "$waited" -eq 0 ]; then
      echo "⏳ Another bootstrap is building in $JS_DIR, waiting for it ..."
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$BUILD_LOCK/pid"
  holds_build_lock=1
}

# Leaves this directory as the run found it, whether it succeeded or not.
release_build_lock() {
  [ -n "$holds_build_lock" ] || return 0
  clean_bundler_outputs
  if [ -n "$copied_config" ]; then
    rm -f "${JS_DIR:?}/${COPIED_CONFIG_NAME:?}"
  fi
  rm -rf "${BUILD_LOCK:?}"
}

# Switches this checkout to --core-ref. No network access once the checkout is at that ref.
sync_core_ref() {
  local recorded=""
  [ -f "$CORE_REF_FILE" ] && recorded="$(cat "$CORE_REF_FILE")"
  if [ "$recorded" = "$CORE_REF" ] && [ "${WDK_REFRESH:-}" != 1 ]; then
    return 0
  fi
  [ -e "$CORE_DIR/.git" ] || die "--core-ref needs $CORE_DIR to be a git clone of wdk-core-swift"

  # The bundler's --install may rewrite the two package files; any other change is somebody's work.
  local foreign_changes
  foreign_changes="$(git -C "$CORE_DIR" status --porcelain --untracked-files=no | awk '{ print $NF }' \
    | grep -v -x -F -e 'js/package.json' -e 'js/package-lock.json' || true)"
  if [ -n "$foreign_changes" ]; then
    die "refusing to switch $CORE_DIR to '$CORE_REF': it has local changes to
$foreign_changes
--core-ref is for a clone the build manages. For your own checkout, omit --core-ref."
  fi

  echo "🔄 Switching wdk-core-swift to '$CORE_REF' ..."
  git -C "$CORE_DIR" fetch --quiet --tags --force origin '+refs/heads/*:refs/remotes/origin/*' \
    || die "could not fetch wdk-core-swift to reach '$CORE_REF' (offline?)"

  local target="" candidate
  for candidate in "origin/$CORE_REF" "refs/tags/$CORE_REF" "refs/tags/v$CORE_REF" "$CORE_REF"; do
    if target="$(git -C "$CORE_DIR" rev-parse --verify --quiet "$candidate^{commit}")"; then
      break
    fi
    target=""
  done
  [ -n "$target" ] || die "'$CORE_REF' is not a branch, tag, version or commit of wdk-core-swift"

  if [ "$(git -C "$CORE_DIR" rev-parse HEAD)" != "$target" ]; then
    git -C "$CORE_DIR" checkout --quiet --force --detach "$target"
    printf '%s\n' "$CORE_REF" > "$CORE_REF_FILE"
    # The scripts themselves may differ at the new revision: start over with them.
    exec "$0" "${ORIGINAL_ARGS[@]}"
  fi
  printf '%s\n' "$CORE_REF" > "$CORE_REF_FILE"
}

# Fails unless Node.js satisfies the bundler's `engines` range (mirrored in package.json).
check_node_version() {
  node -e '
    const [major, minor] = process.versions.node.split(".").map(Number)
    const supported = (major === 22 && minor >= 21) || (major === 24 && minor >= 9) || major > 24
    process.exit(supported ? 0 : 1)
  ' || die "Node.js $(node --version) cannot run @tetherto/wdk-worklet-bundler (needs ^22.21.0 or >=24.9.0)"
}

# Prints a digest of everything the outputs depend on.
fingerprint() {
  {
    printf 'platform=%s engine=%s barekit=%s\n' "$PLATFORM" "$ENGINE" "$BAREKIT_TAG"
    printf 'bundle=%s addons=%s frameworks=%s\n' "$BUNDLE_OUT" "$ADDONS_OUT" "$BAREKIT_OUT"
    cat "$CONFIG" "$JS_DIR/package.json" "$JS_DIR/package-lock.json" "$JS_DIR"/scripts/*.sh
  } | shasum -a 256 | cut -d' ' -f1
}

# Succeeds when the bundle and every addon recorded by the last run are still in place.
outputs_present() {
  [ -f "$BUNDLE_OUT" ] && [ -f "$ADDONS_OUT/$ADDONS_MANIFEST" ] || return 1
  local name
  while IFS= read -r name; do
    [ -e "$ADDONS_OUT/$name" ] || return 1
  done < "$ADDONS_OUT/$ADDONS_MANIFEST"
}

# Replaces what the previous run put in --addons-out with the freshly linked addons. Anything
# else in that directory is left alone.
install_addons() {
  local source_dir="$1" name entry
  mkdir -p "$ADDONS_OUT"
  if [ -f "$ADDONS_OUT/$ADDONS_MANIFEST" ]; then
    while IFS= read -r name; do
      case "$name" in ''|*/*) continue ;; esac
      rm -rf "${ADDONS_OUT:?}/${name:?}"
    done < "$ADDONS_OUT/$ADDONS_MANIFEST"
  fi
  : > "$ADDONS_OUT/$ADDONS_MANIFEST.next"
  for entry in "$source_dir"/*; do
    name="$(basename "$entry")"
    rm -rf "${ADDONS_OUT:?}/${name:?}"
    mv "$entry" "$ADDONS_OUT/$name"
    printf '%s\n' "$name" >> "$ADDONS_OUT/$ADDONS_MANIFEST.next"
  done
  mv "$ADDONS_OUT/$ADDONS_MANIFEST.next" "$ADDONS_OUT/$ADDONS_MANIFEST"
}

ORIGINAL_ARGS=("$@")
PLATFORM=""
APP_ROOT=""
CONFIG="wdk.config.js"
BUNDLE_OUT=""
ADDONS_OUT="addons"
BAREKIT_OUT="frameworks"
ENGINE="v8"
BAREKIT_TAG=""
CORE_REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --platform|--app-root|--config|--bundle-out|--addons-out|--barekit-out|--engine|--barekit-tag|--core-ref)
      [ $# -ge 2 ] || die "$1 needs a value (see --help)"
      case "$1" in
        --platform)    PLATFORM="$2" ;;
        --app-root)    APP_ROOT="$2" ;;
        --config)      CONFIG="$2" ;;
        --bundle-out)  BUNDLE_OUT="$2" ;;
        --addons-out)  ADDONS_OUT="$2" ;;
        --barekit-out) BAREKIT_OUT="$2" ;;
        --engine)      ENGINE="$2" ;;
        --barekit-tag) BAREKIT_TAG="$2" ;;
        --core-ref)    CORE_REF="$2" ;;
      esac
      shift 2
      ;;
    *) die "unexpected argument '$1' (see --help)" ;;
  esac
done

case "$PLATFORM" in
  ios)   default_bundle="wdk-worklet.mobile.bundle"; bundler_addons_dir="ios-addons" ;;
  macos) default_bundle="wdk-worklet.macos.bundle";  bundler_addons_dir="mac-addons" ;;
  *)     die "--platform must be ios or macos (got '$PLATFORM')" ;;
esac
case "$ENGINE" in
  v8|javascriptcore) ;;
  *) die "--engine must be v8 or javascriptcore (got '$ENGINE')" ;;
esac
[ -n "$APP_ROOT" ] || die "--app-root is required"
[ -d "$APP_ROOT" ] || die "--app-root '$APP_ROOT' is not a directory"
APP_ROOT="$(cd "$APP_ROOT" && pwd)"

if [ -n "$CORE_REF" ]; then
  sync_core_ref
fi

CONFIG="$(resolve_path "$CONFIG")"
BUNDLE_OUT="$(resolve_path "${BUNDLE_OUT:-$default_bundle}")"
ADDONS_OUT="$(resolve_path "$ADDONS_OUT")"
BAREKIT_OUT="$(resolve_path "$BAREKIT_OUT")"
[ -f "$CONFIG" ] || die "worklet configuration not found: $CONFIG"

barekit_args=(--platform "$PLATFORM" --dest "$BAREKIT_OUT" --engine "$ENGINE")
if [ -n "$BAREKIT_TAG" ]; then
  barekit_args+=(--tag "$BAREKIT_TAG")
fi

for tool in node npm git curl unzip shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but was not found on PATH"
done
check_node_version

if [ "$ENGINE" = "javascriptcore" ]; then
  node --input-type=module -e '
    const { pathToFileURL } = await import("node:url")
    const loaded = await import(pathToFileURL(process.argv[1]).href)
    const config = loaded.default ?? loaded
    process.exit(config.options?.convertEsmToCjs === true ? 0 : 1)
  ' "$CONFIG" \
    || die "JavaScriptCore cannot load ES modules: set options.convertEsmToCjs to true in $CONFIG"
fi

# First, so that an unsupported BareKit release or framework stops the run before any other work.
# It returns at once when the framework is already in place.
"$FETCH_BAREKIT" "${barekit_args[@]}"

stamp="$CACHE_DIR/$(printf '%s' "$APP_ROOT $PLATFORM" | shasum -a 256 | cut -c1-16).stamp"
if [ "${WDK_REFRESH:-}" != 1 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(fingerprint)" ] && outputs_present; then
  echo "✓ Worklet bundle and addons are up to date ($PLATFORM)"
  exit 0
fi

holds_build_lock=""
copied_config=""
trap release_build_lock EXIT
acquire_build_lock

echo "📦 Installing the pinned JavaScript toolchain ..."
(cd "$JS_DIR" && npm install --no-audit --no-fund --loglevel=error)

if [ "$(cd "$(dirname "$CONFIG")" && pwd)" = "$JS_DIR" ]; then
  config_name="$(basename "$CONFIG")"
else
  cp "$CONFIG" "$JS_DIR/$COPIED_CONFIG_NAME"
  config_name="$COPIED_CONFIG_NAME"
  copied_config=1
fi

clean_bundler_outputs
log="$CACHE_DIR/generate-$PLATFORM.log"
echo "🔧 Building the worklet bundle and linking the addons ($PLATFORM) ..."
if ! (cd "$JS_DIR" && "$BUNDLER" generate --config "$config_name" --transport jsonrpc --install </dev/null) >"$log" 2>&1; then
  tail -n 40 "$log" >&2
  die "the bundler failed (full log: $log)"
fi

bundle_source=""
for candidate in $BUNDLER_BUNDLE_CANDIDATES; do
  if [ -f "$JS_DIR/$candidate" ]; then
    bundle_source="$JS_DIR/$candidate"
    break
  fi
done
addons_source="$JS_DIR/$bundler_addons_dir"
if [ -z "$bundle_source" ] || [ -z "$(ls -A "$addons_source" 2>/dev/null)" ]; then
  die "the bundler did not write the $PLATFORM bundle and addons to its default locations.
Check $CONFIG: it must not have an 'output' section, and options.targets must list
$PLATFORM hosts (full log: $log)"
fi

mkdir -p "$(dirname "$BUNDLE_OUT")"
rm -f "${BUNDLE_OUT:?}"
mv "$bundle_source" "$BUNDLE_OUT"
install_addons "$addons_source"

fingerprint > "$stamp"

addon_count="$(grep -c -E '\.(xc)?framework$' "$ADDONS_OUT/$ADDONS_MANIFEST" || true)"
echo "✅ WDK worklet ready ($PLATFORM, $ENGINE)"
echo "   bundle   $BUNDLE_OUT"
echo "   addons   $ADDONS_OUT ($addon_count frameworks)"
echo "   BareKit  $BAREKIT_OUT/BareKit.xcframework"
