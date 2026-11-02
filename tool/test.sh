#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <unit|local|check|host|all> [paths...]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
tier=$1
shift

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# Native asset hooks rebuild when any variable they hash moves, and each shell
# carries its own PATH, temp dir and dev shell generation; every run takes the flake's.
if command -v nix >/dev/null; then
  eval "$(nix develop -i --keep HOME -c bash -c 'export -p' 2>/dev/null |
    grep -E '^declare -x (PATH|NIX_[A-Za-z0-9_]+|ANDROID_[A-Z_]+)=' || true)"
  PATH=$PATH:/run/wrappers/bin:/etc/profiles/per-user/${USER:-}/bin:$HOME/.nix-profile/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin
  unset NIX_AAPT2_BINARY_PATH NIX_BUILD_TOP TMPDIR TEMP TMP
fi
jobs=$(getconf _NPROCESSORS_ONLN)

# A second run beside the first stalls both, so it waits its turn.
if command -v flock >/dev/null; then
  mkdir -p .dart_tool
  exec 9>.dart_tool/test.lock
  flock -n 9 || {
    echo "test: waiting for the run already holding .dart_tool/test.lock" >&2
    flock 9
  }
fi

# A testWidgets teardown that never completes ignores --timeout and hangs the run.
run() {
  local limit=${UPGRADE_TEST_TIMEOUT:-600}
  local codes pub=()
  # The implicit pub get costs a second or two a run; skip it while the resolution is current.
  local config=.dart_tool/package_config.json
  if [ -f "$config" ] && [ -z "$(find pubspec.yaml pubspec.lock packages/*/pubspec.yaml \
    .dart_tool/{dart_mosh,dartssh2,flterm,libghostty,pointycastle}/pubspec.yaml -newer "$config" 2>/dev/null)" ]; then
    pub=(--no-pub)
  fi
  {
    # native_toolchain_c probes for MSVC on every OS; drop its PATH dump.
    timeout --kill-after=10 "$limit" flutter test "${pub[@]}" --reporter json "$@" 2>&1 |
      sed -e '/which: no vswhere\.exe in /d' -e '/^No Visual Studio installation found/d' |
      testfmt
    codes=("${PIPESTATUS[@]}")
  } || true
  if [ "${codes[0]}" -eq 124 ]; then
    echo "flutter test passed ${limit}s and was killed; set UPGRADE_TEST_TIMEOUT to allow more" >&2
  fi
  [ "${codes[0]}" -eq 0 ] && [ "${codes[2]}" -eq 0 ]
}

unit() {
  tool/test-shards.sh "$jobs"
  run test/shards/unit.dart
}

local_tier() {
  if [ $# -gt 0 ]; then
    run -j "$jobs" --exclude-tags host "$@"
    return
  fi
  local out=.dart_tool/test status=0
  mkdir -p "$out"
  tool/test-shards.sh "$jobs"
  started=$SECONDS
  run -j "$jobs" --file-reporter "json:$out/report.json" test/shards/shard_*.dart || status=$?
  wall=$((SECONDS - started))
  if ! dart tool/test_times.dart "$out/report.json" "$out/times.tsv" ${file_budget:+--budget "$file_budget"}; then
    [ "$status" -ne 0 ] || status=1
  fi
  return "$status"
}

inputs() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1
  {
    flutter --version
    echo "${LIBGHOSTTY_REV:-}"
    git ls-files -z -co --exclude-standard -- lib test packages assets plugins tool \
      pubspec.yaml pubspec.lock dart_test.yaml analysis_options.yaml |
      xargs -0 sha256sum 2>/dev/null || true
  } | sha256sum | cut -c1-16
}

full() {
  local passed=.dart_tool/test/passed key status=0
  key=$(inputs)
  if [ -z "${UPGRADE_TEST_FORCE:-}" ] && [ "$(cat "$passed" 2>/dev/null)" = "$key" ]; then
    echo "test: inputs $key already passed; UPGRADE_TEST_FORCE=1 runs them again"
    return 0
  fi
  local_tier || status=$?
  if [ "$status" -eq 0 ] && [ "$(inputs)" = "$key" ]; then
    echo "$key" >"$passed"
  fi
  echo "test: inputs $key"
  return "$status"
}

check() {
  local wall_budget=${TEST_WALL_BUDGET:-60}
  file_budget=${TEST_FILE_BUDGET:-45}
  local status=0
  local_tier || status=$?
  if [ "$wall" -gt "$wall_budget" ]; then
    echo "test budget: the suite took ${wall}s, over its ${wall_budget}s" >&2
    status=1
  fi
  echo "test: ${wall}s of the ${wall_budget}s budget"
  return "$status"
}

host() {
  nix run .#host-up
  run -j 1 --tags host "${@:-test/host}"
}

case $tier in
  unit)
    [ $# -eq 0 ] || usage
    unit
    ;;
  local)
    if [ $# -gt 0 ]; then local_tier "$@"; else full; fi
    ;;
  check)
    [ $# -eq 0 ] || usage
    check
    ;;
  host) host "$@" ;;
  all)
    [ $# -eq 0 ] || usage
    local_tier
    host
    ;;
  *) usage ;;
esac
