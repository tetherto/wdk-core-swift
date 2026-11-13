#!/bin/bash
set -euo pipefail

# =============================================================================
# fetch-barekit.sh
#
# Provisions BareKit.xcframework from a BareKit 2.x GitHub release
# (https://github.com/holepunchto/bare-kit/releases).
#
# This line of WdkCore runs on the BareKit 2.x prebuilds and is built and
# tested with the V8 engine only. BareKit 3.x is a different distribution: it
# publishes no prebuilds.zip and has no Objective-C API. It arrives with the
# bare-stow rework (tetherto/wdk-worklet-bundler#84, phase 3a), so 3.x is
# rejected here.
#
# Usage:
#   fetch-barekit.sh --platform <ios|macos> --dest <dir>
#                    [--tag <v2.x.y>] [--engine <v8|javascriptcore>]
#
# Options:
#   --platform   ios or macos. Selects which folder of the archive is extracted.
#   --dest       Directory that receives BareKit.xcframework (created if missing).
#   --tag        BareKit 2.x release tag (default: v2.5.5).
#   --engine     v8 (default) or javascriptcore. JavaScriptCore is discouraged,
#                see js/README.md.
#
# Environment:
#   WDK_REFRESH=1   Extract again even if the framework is already in place.
#
# Behaviour:
#   - A framework this script installed is left alone while tag, engine and
#     platform are unchanged, so repeat runs are instant and work offline.
#   - A framework somebody else put in --dest (no release marker next to it) is
#     never replaced unless WDK_REFRESH=1. Delete it to fetch the pinned release.
#   - The release archive (about 400 MB, every platform) is kept in
#     ~/Library/Caches/wdk-core-swift so other platforms, engines and repeat
#     runs do not download it again. Delete that directory to force a download.
#
# Exit status: 0 on success, 1 on any error (message on stderr).
# =============================================================================

readonly DEFAULT_TAG="v2.5.5"
readonly SUPPORTED_TAG_PATTERN='^v2\.[0-9]+\.[0-9]+$'
readonly RELEASES_URL="https://github.com/holepunchto/bare-kit/releases/download"
readonly ARCHIVE_NAME="prebuilds.zip"
readonly CACHE_DIR="$HOME/Library/Caches/wdk-core-swift/barekit"
readonly FRAMEWORK_NAME="BareKit.xcframework"
readonly MARKER_NAME=".barekit-release"
readonly V2_API_HEADER="BareKit.h"
readonly V2_API_SYMBOL="@interface BareWorklet"

die() {
  echo "fetch-barekit: $*" >&2
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^# Environment:/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Fails unless the framework exposes the Bare Kit v2 Objective-C API this package links against.
verify_v2_api() {
  local framework="$1" header
  header="$(find "$framework" -name "$V2_API_HEADER" -path '*Headers*' -print -quit 2>/dev/null)"
  if [ -z "$header" ] || ! grep -q "$V2_API_SYMBOL" "$header"; then
    die "$framework is not a BareKit 2.x framework (no '$V2_API_SYMBOL' in $V2_API_HEADER).
WdkCore on this line needs BareKit 2.x (tested: $DEFAULT_TAG, V8). BareKit 3.x has no Objective-C API
and is adopted with the bare-stow rework (tetherto/wdk-worklet-bundler#84, phase 3a).
Remove $framework and run again to fetch $DEFAULT_TAG."
  fi
}

PLATFORM=""
DEST=""
TAG="$DEFAULT_TAG"
ENGINE="v8"

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --dest)     DEST="${2:-}"; shift 2 ;;
    --tag)      TAG="${2:-}"; shift 2 ;;
    --engine)   ENGINE="${2:-}"; shift 2 ;;
    --help|-h)  usage; exit 0 ;;
    *)          die "unexpected argument '$1' (see --help)" ;;
  esac
done

case "$PLATFORM" in
  ios)   archive_folder="ios" ;;
  macos) archive_folder="darwin" ;;
  *)     die "--platform must be ios or macos (got '${PLATFORM}')" ;;
esac
case "$ENGINE" in
  v8) ;;
  javascriptcore) archive_folder="$archive_folder-javascriptcore" ;;
  *) die "--engine must be v8 or javascriptcore (got '${ENGINE}')" ;;
esac
[ -n "$DEST" ] || die "--dest is required"
if ! [[ "$TAG" =~ $SUPPORTED_TAG_PATTERN ]]; then
  die "'$TAG' is not a BareKit 2.x release tag (expected v2.<minor>.<patch>).
BareKit 3.x publishes no $ARCHIVE_NAME and needs bare-stow; it arrives in phase 3a of
tetherto/wdk-worklet-bundler#84. The tested release is $DEFAULT_TAG."
fi

if [ "$ENGINE" != "v8" ]; then
  echo "⚠️  JavaScriptCore is discouraged: it has known issues that are yours to handle, see" >&2
  echo "   js/README.md. V8 is the default and the tested engine." >&2
fi

framework="$DEST/$FRAMEWORK_NAME"
marker="$DEST/$MARKER_NAME"
expected_marker="$TAG $ENGINE $PLATFORM"
installed_marker=""
[ -f "$marker" ] && installed_marker="$(cat "$marker")"

if [ "${WDK_REFRESH:-}" != 1 ] && [ -d "$framework" ]; then
  if [ "$installed_marker" = "$expected_marker" ]; then
    verify_v2_api "$framework"
    echo "✓ BareKit $TAG ($ENGINE, $PLATFORM) already in $DEST"
    exit 0
  fi
  if [ -z "$installed_marker" ]; then
    verify_v2_api "$framework"
    echo "✓ Using the $FRAMEWORK_NAME already in $DEST (not installed by this script)."
    echo "  Delete it to fetch BareKit $TAG ($ENGINE) instead."
    exit 0
  fi
fi

archive="$CACHE_DIR/$TAG/$ARCHIVE_NAME"
if [ ! -f "$archive" ]; then
  mkdir -p "$(dirname "$archive")"
  echo "⬇️  Downloading BareKit $TAG ($ARCHIVE_NAME, about 400 MB) ..."
  if ! curl --fail --location --retry 3 --progress-bar --output "$archive.partial" \
      "$RELEASES_URL/$TAG/$ARCHIVE_NAME"; then
    rm -f "${archive:?}.partial"
    die "could not download $RELEASES_URL/$TAG/$ARCHIVE_NAME.
Check the tag exists at https://github.com/holepunchto/bare-kit/releases and that you are online."
  fi
  mv "$archive.partial" "$archive"
fi

if ! unzip -Z1 "$archive" >/dev/null 2>&1; then
  rm -f "${archive:?}"
  die "the cached $ARCHIVE_NAME for $TAG was unreadable and has been removed. Run again to download it."
fi

# The xcframework is located through the archive listing so that its nesting inside the folder
# does not matter.
entry="$(unzip -Z1 "$archive" | grep -m1 -E "^$archive_folder/(.*/)?$FRAMEWORK_NAME/Info\.plist$" || true)"
if [ -z "$entry" ]; then
  available="$(unzip -Z1 "$archive" | cut -d/ -f1 | sort -u | tr '\n' ' ')"
  die "'$archive_folder/' holds no $FRAMEWORK_NAME in $ARCHIVE_NAME of $TAG. Folders in the archive: $available"
fi
framework_in_archive="${entry%/Info.plist}"

staging="$(mktemp -d)"
trap 'rm -rf "${staging:?}"' EXIT
unzip -q -o "$archive" "$framework_in_archive/*" -d "$staging"
verify_v2_api "$staging/$framework_in_archive"

mkdir -p "$DEST"
rm -rf "${framework:?}"
mv "$staging/$framework_in_archive" "$framework"
# Archives downloaded from GitHub carry the quarantine attribute, which makes dyld reject the framework.
xattr -dr com.apple.quarantine "$framework" 2>/dev/null || true
printf '%s\n' "$expected_marker" > "$marker"

echo "✓ BareKit $TAG ($ENGINE, $PLATFORM) → $framework"
