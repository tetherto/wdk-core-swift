#!/bin/bash
# Exercise the helper in disposable directories without Swift or native frameworks.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wdk-framework-cleanup.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup() {
  case_dir="$TEMP_DIR/$1"
  mkdir -p "$case_dir/Scripts" "$case_dir/bin" "$case_dir/unrelated-target"
  cp "$SCRIPT_DIR/test-with-frameworks.sh" "$case_dir/Scripts/"
  mkdir -p "$case_dir/Tests/Resources/macos/Frameworks/"{bare-a,sodium-b}.framework
  printf 'keep me\n' > "$case_dir/unrelated-file.framework"
  ln -s unrelated-target "$case_dir/unrelated-link.framework"
  cat > "$case_dir/bin/swift" <<'SWIFT'
#!/bin/bash
set -e
[ -L bare-a.framework ] && [ -L sodium-b.framework ]
printf '%s\n' "$@" > swift-arguments
case "$TEST_MODE" in
  failure) exit 7 ;;
  INT|TERM) kill -s "$TEST_MODE" "$PPID" ;;
  replace)
    rm bare-a.framework sodium-b.framework
    printf 'replacement\n' > bare-a.framework
    ln -s unrelated-target sodium-b.framework
    ;;
esac
SWIFT
  chmod +x "$case_dir/bin/swift"
}

run_helper() {
  actual_status=0
  PATH="$case_dir/bin:$PATH" TEST_MODE="$1" bash "$case_dir/Scripts/test-with-frameworks.sh" \
    --filter 'Test With Spaces' > "$case_dir/output" 2>&1 || actual_status=$?
  [ "$actual_status" = "$2" ] || fail "$1: expected exit $2, got $actual_status"
  [ "$(cat "$case_dir/unrelated-file.framework")" = 'keep me' ] || fail 'unrelated file changed'
  [ "$(readlink "$case_dir/unrelated-link.framework")" = unrelated-target ] || fail 'unrelated link changed'
  [ -d "$case_dir/unrelated-target" ] || fail 'unrelated target removed'
}

check_cleaned() {
  for name in bare-a sodium-b; do
    [ ! -e "$case_dir/$name.framework" ] && [ ! -L "$case_dir/$name.framework" ] || fail "$name link remains"
    [ -d "$case_dir/Tests/Resources/macos/Frameworks/$name.framework" ] || fail "$name target removed"
  done
}

for mode in success failure INT TERM; do
  setup "$mode"
  case "$mode" in
    success) expected=0 ;;
    failure) expected=7 ;;
    INT) expected=130 ;;
    TERM) expected=143 ;;
  esac
  run_helper "$mode" "$expected"
  check_cleaned
  tail -2 "$case_dir/swift-arguments" > "$case_dir/actual-arguments"
  printf '%s\n' --filter 'Test With Spaces' > "$case_dir/expected-arguments"
  cmp "$case_dir/expected-arguments" "$case_dir/actual-arguments"
  echo "PASS: $mode cleanup and argument forwarding"
done

for kind in file directory symlink dangling; do
  setup "collision-$kind"
  collision="$case_dir/sodium-b.framework"
  case "$kind" in
    file) printf 'existing\n' > "$collision" ;;
    directory) mkdir "$collision"; printf 'existing\n' > "$collision/marker" ;;
    symlink) ln -s unrelated-target "$collision" ;;
    dangling) ln -s missing-target "$collision" ;;
  esac
  run_helper success 1
  [ ! -e "$case_dir/swift-arguments" ] || fail 'Swift ran despite collision'
  [ ! -L "$case_dir/bare-a.framework" ] || fail 'earlier link leaked after collision'
  case "$kind" in
    file) [ "$(cat "$collision")" = existing ] || fail 'existing file changed' ;;
    directory) [ "$(cat "$collision/marker")" = existing ] || fail 'existing directory changed' ;;
    symlink) [ "$(readlink "$collision")" = unrelated-target ] || fail 'existing link changed' ;;
    dangling) [ "$(readlink "$collision")" = missing-target ] || fail 'dangling link changed' ;;
  esac
  echo "PASS: $kind collision preserves existing path and cleans earlier links"
done

setup replacement
run_helper replace 0
[ "$(cat "$case_dir/bare-a.framework")" = replacement ] || fail 'replacement file removed'
[ "$(readlink "$case_dir/sodium-b.framework")" = unrelated-target ] || fail 'replacement link removed'
echo 'PASS: cleanup preserves paths replaced during the run'

setup no-addons
rm -rf "$case_dir/Tests/Resources/macos/Frameworks"
printf '#!/bin/bash\nexit 0\n' > "$case_dir/bin/swift"
run_helper success 0
echo 'PASS: no matching frameworks'
