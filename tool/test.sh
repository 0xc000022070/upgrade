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
jobs=$(getconf _NPROCESSORS_ONLN)

# A testWidgets teardown that never completes ignores --timeout and hangs the run.
run() {
  local limit=${STRIKED_TEST_TIMEOUT:-600}
  local codes
  {
    timeout --kill-after=10 "$limit" flutter test --reporter json "$@" 2>&1 | testfmt
    codes=("${PIPESTATUS[@]}")
  } || true
  if [ "${codes[0]}" -eq 124 ]; then
    echo "flutter test passed ${limit}s and was killed; set STRIKED_TEST_TIMEOUT to allow more" >&2
  fi
  [ "${codes[0]}" -eq 0 ] && [ "${codes[1]}" -eq 0 ]
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
  local) local_tier "$@" ;;
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
