#!/usr/bin/env bash
# xterm is a hosted dependency and the patches beside it are what we changed.
# Nothing in pub applies them, so they are applied into the resolved package in
# the pub cache, which is the copy the analyzer, the IDE and the build all read.
#
#   sync      apply the series when the cache is pristine, and say so otherwise
#   apply     overwrite the cache with pristine plus the series
#   generate  rewrite the series from whatever the cache holds now
#   verify    prove the cache is pristine plus the series and nothing else
#   reset     put the cache back to pristine
#   without   apply the series with one patch dropped
#
# Editing xterm means editing the cache and running `generate`. Dropping one
# patch and running the series is how a behaviour gets bisected back to the
# change that introduced it.
#
# The cache is shared by every project on this machine, so what is written
# there is upstream's own version with our lines in it. `reset` undoes that,
# and so does `dart pub cache repair`.
set -euo pipefail

readonly UPSTREAM_VERSION=4.0.0
# sha256 over the sorted sha256 of every .dart file under lib/, so a refetched
# upstream is checked against the source the series was cut from.
readonly UPSTREAM_LIB_SHA=12bd4729255b42339be8858b09a320c167556c8429b171bce627a7c27461126a

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PATCHES="$ROOT/packages/xterm/patches"
# Kept out of the pub cache and out of git: the cache holds the patched copy,
# so the only pristine upstream on this machine is the one we keep ourselves.
readonly PRISTINE="$ROOT/.dart_tool/xterm-$UPSTREAM_VERSION-pristine"
readonly CACHE="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/xterm-$UPSTREAM_VERSION"

# One entry per behaviour, in the order they apply: <file>|<subject>|<paths...>
# scroll-forwarding is one patch and not three because the local pointer
# position, the mouseMode.reportScroll condition and the deferred swap rewrite
# the same hunks; split any finer and the patches stop being what we did.
#
# A whole file is copied per entry, so a file belongs to exactly one of them. A
# change reaching two files that already sit in different entries is carried by
# both of their subjects rather than by an entry of its own.
readonly -a CONCERNS=(
  "01-wheel-button-ids|a wheel button is 64-67, not 68-71|lib/src/core/mouse/button.dart"
  "02-scroll-forwarding|scroll forwards on a local position and swaps on the last lift|lib/src/ui/scroll_handler.dart lib/src/ui/infinite_scroll_view.dart"
  "03-keyboard-on-tap|a tap on the terminal need not raise the IME, and a scroll reports a screen row|lib/src/terminal_view.dart"
  "04-touch-selection|a touch selection anchors at pointer-down and takes tokens whole, and a mouse report names a screen row|lib/src/ui/gesture/gesture_handler.dart lib/src/ui/render.dart lib/src/core/buffer/token.dart lib/src/core/buffer/buffer.dart lib/core.dart"
  "05-row-index-through-trim|a row's index follows it through a trim and a shift|lib/src/utils/circular_buffer.dart"
  "06-report-apart-from-output|what the terminal answers is reported apart from what the user typed|lib/src/terminal.dart"
)

die() {
  echo "xterm-patches: $*" >&2
  exit 1
}

lib_sha() {
  (cd "$1" && find . -type f -name '*.dart' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

# An unmutated 4.0.0, fetched into a cache of its own so the patched one is
# never the thing we diff against.
pristine_lib() {
  if [[ ! -d $PRISTINE/lib ]]; then
    echo "fetching pristine xterm $UPSTREAM_VERSION" >&2
    local fetch
    fetch=$(mktemp -d)
    PUB_CACHE="$fetch" dart pub cache add xterm --version "$UPSTREAM_VERSION" >&2
    mkdir -p "$PRISTINE"
    cp -r "$fetch/hosted/pub.dev/xterm-$UPSTREAM_VERSION/lib" "$PRISTINE/lib"
    chmod -R u+w "$PRISTINE/lib"
    rm -rf "$fetch"
  fi

  local got
  got=$(lib_sha "$PRISTINE/lib")
  [[ $got == "$UPSTREAM_LIB_SHA" ]] ||
    die "pristine xterm $UPSTREAM_VERSION does not match the pinned hash"$'\n'"  want $UPSTREAM_LIB_SHA"$'\n'"  got  $got"

  echo "$PRISTINE/lib"
}

# The resolved package, which is only there after a `pub get`. Everything here
# overwrites it, so the path is checked rather than trusted: a PUB_CACHE that
# points somewhere unexpected must not turn into an `rm -rf` on it.
cache_lib() {
  [[ $CACHE == */hosted/pub.dev/xterm-$UPSTREAM_VERSION ]] ||
    die "refusing to work on $CACHE"
  [[ -d $CACHE/lib ]] ||
    die "xterm $UPSTREAM_VERSION is not in the pub cache; run \`flutter pub get\`"
  echo "$CACHE/lib"
}

# A git tree holding pristine lib/, one commit per behaviour. git does the hunk
# splitting and guarantees the series applies in order.
build_series() {
  local pristine=$1 package=$2 work=$3

  mkdir -p "$work"
  cp -r "$pristine" "$work/lib"
  chmod -R u+w "$work/lib"

  git -C "$work" init -q
  git -C "$work" add -A
  git -C "$work" -c user.email=x -c user.name=x -c commit.gpgsign=false commit -qm "xterm $UPSTREAM_VERSION"

  local entry name subject paths path
  for entry in "${CONCERNS[@]}"; do
    IFS='|' read -r name subject paths <<<"$entry"
    for path in $paths; do
      [[ -f $package/$path ]] || die "$path is in the series but not in the package"
      mkdir -p "$work/$(dirname "$path")"
      cp "$package/$path" "$work/$path"
    done
    git -C "$work" add -A
    git -C "$work" -c user.email=x -c user.name=x -c commit.gpgsign=false commit -qm "$subject"
  done
}

generate() {
  local pristine work
  pristine=$(pristine_lib)
  cache_lib >/dev/null
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT

  build_series "$pristine" "$CACHE" "$work"

  rm -rf "$PATCHES"
  mkdir -p "$PATCHES"

  # `git diff` of each step rather than format-patch: no commit id, no date, so
  # regenerating an unchanged package rewrites nothing.
  local i=1 entry name subject
  for entry in "${CONCERNS[@]}"; do
    IFS='|' read -r name subject _ <<<"$entry"
    local rev
    rev=$(git -C "$work" rev-list --reverse HEAD | sed -n "$((i + 1))p")
    {
      echo "# $subject"
      echo "#"
      echo "# Against xterm $UPSTREAM_VERSION. Regenerate with \`just xterm-patches\`."
      echo
      git -C "$work" diff --no-color --no-ext-diff "$rev~1" "$rev"
    } >"$PATCHES/$name.patch"
    echo "  $name.patch"
    i=$((i + 1))
  done

  # Anything changed in the cache that no patch claims would silently vanish
  # from the series, so the series is only honest if it reproduces the package.
  rm -rf "$work"
  verify
}

# The series applied to a pristine copy, in a directory of its own.
patched_lib() {
  local pristine work
  pristine=$(pristine_lib)
  work=$1

  mkdir -p "$work"
  cp -r "$pristine" "$work/lib"
  chmod -R u+w "$work/lib"

  local patch drop=${2:-}
  for patch in "$PATCHES"/*.patch; do
    [[ -f $patch ]] || die "no patches in $PATCHES"
    [[ -n $drop && $(basename "$patch" .patch) == "$drop" ]] && continue
    (cd "$work" && git apply -p1 --whitespace=nowarn "$patch") ||
      die "$(basename "$patch") does not apply${drop:+ without $drop; they are one concern}"
  done
}

# Which of the three states the cache is in, so a caller can tell an unpatched
# package from one somebody is in the middle of editing.
state() {
  local cache work
  cache=$(cache_lib)
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT
  cp -r "$(pristine_lib)" "$work/pristine"
  patched_lib "$work/patched" >/dev/null

  local answer=edited
  if diff -rqN --exclude='.*' "$work/pristine" "$cache" >/dev/null 2>&1; then
    answer=pristine
  elif diff -rqN --exclude='.*' "$work/patched/lib" "$cache" >/dev/null 2>&1; then
    answer=patched
  fi
  rm -rf "$work"
  echo "$answer"
}

write_cache() {
  local drop=${1:-} cache work
  cache=$(cache_lib)
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT

  patched_lib "$work" "$drop" >/dev/null
  rm -rf "$cache"
  cp -r "$work/lib" "$cache"
  rm -rf "$work"
}

apply() {
  write_cache
  echo "xterm $UPSTREAM_VERSION in the pub cache carries the series"
}

reset_cache() {
  local pristine cache
  pristine=$(pristine_lib)
  cache=$(cache_lib)
  rm -rf "$cache"
  cp -r "$pristine" "$cache"
  echo "xterm $UPSTREAM_VERSION in the pub cache is upstream's again"
}

# What a build runs first: an untouched package is patched, one already
# carrying the series is left alone, and one being edited is reported and then
# left alone too, because the edit is the only copy of itself and the run it is
# about to be tested by is the reason it exists. `verify` is what refuses it,
# at the gate, where an edit nobody wrote down is a change about to be lost.
sync() {
  case "$(state)" in
  patched) echo "xterm $UPSTREAM_VERSION already carries the series" ;;
  pristine) apply ;;
  edited)
    echo "xterm $UPSTREAM_VERSION in the pub cache is neither upstream's nor the series;" >&2
    echo "  leaving it. Record it with \`just xterm-patches\`, or drop it with \`just xterm-apply\`." >&2
    ;;
  esac
}

verify() {
  local cache work
  cache=$(cache_lib)
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT

  patched_lib "$work" >/dev/null
  if ! diff -ruN --exclude='.*' "$work/lib" "$cache" >/dev/null; then
    echo "the series does not reproduce the xterm in the pub cache:" >&2
    diff -ruN --exclude='.*' "$work/lib" "$cache" | head -40 >&2
    die "run \`just xterm-patches\` to rewrite it, or \`just xterm-apply\` to discard it"
  fi
  echo "the pub cache holds xterm $UPSTREAM_VERSION plus the series, and nothing else"
}

# Rebuild the package from the series with one patch left out, so a behaviour
# can be tried without the change that is suspected of causing it.
#
# 03 and 06 add API that dazzle calls (keyboardOnTap in shell_terminal.dart,
# onReport in shell_sessions.dart), so dropping either wants those call sites
# edited too. 04 drops clean for a build: the token API it adds is only read by
# test/terminal_token_test.dart. 01, 02 and 05 change behaviour and no surface.
without() {
  local drop=${1:-}
  [[ -n $drop ]] || die "usage: xterm-patches.sh without <patch-name>"
  [[ -f $PATCHES/$drop.patch ]] ||
    die "no patch $drop; have: $(cd "$PATCHES" && ls ./*.patch | sed -e 's|\./||' -e 's/\.patch$//' | tr '\n' ' ')"

  write_cache "$drop"
  echo "xterm $UPSTREAM_VERSION in the pub cache carries the series without $drop"
  echo "restore with: just xterm-apply"
}

case "${1:-verify}" in
sync) sync ;;
apply) apply ;;
generate) generate ;;
verify) verify ;;
reset) reset_cache ;;
state) state ;;
without) without "${2:-}" ;;
*) die "usage: xterm-patches.sh [sync|apply|generate|verify|reset|state|without <patch-name>]" ;;
esac
