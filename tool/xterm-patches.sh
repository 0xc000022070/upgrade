#!/usr/bin/env bash
# Our changes to xterm are packages/xterm/patches, one patch per behaviour.
# The package the app builds against is upstream's release with those applied,
# materialised under .dart_tool and never committed; pubspec overrides xterm
# onto it.
#
#   build     materialise it, if the version or the patches moved
#   generate  rewrite the patches from edits made to it
#   verify    prove the patches reproduce it exactly
#   without   materialise it with one patch dropped, to bisect a behaviour
#
# Editing xterm means editing .dart_tool/xterm and running `generate`. A build
# leaves a tree whose patches it already holds alone, so an edit survives until
# it is written down or thrown away with `rm -rf .dart_tool/xterm`.
set -euo pipefail

readonly VERSION=4.0.0
# sha256 over the sorted sha256 of every .dart file under lib/, so a refetched
# upstream is checked against the source the patches were cut from.
readonly LIB_SHA=12bd4729255b42339be8858b09a320c167556c8429b171bce627a7c27461126a

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PATCHES="$ROOT/packages/xterm/patches"
readonly BUILD="$ROOT/.dart_tool/xterm"
readonly UPSTREAM="$ROOT/.dart_tool/xterm-$VERSION-upstream"

readonly TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
  "07-colour-queries|a program that asks what the terminal is drawn in is answered|lib/src/core/color.dart lib/src/core/escape/parser.dart lib/src/core/escape/handler.dart lib/src/core/escape/emitter.dart"
)

die() {
  echo "xterm-patches: $*" >&2
  exit 1
}

lib_sha() {
  (cd "$1" && find . -type f -name '*.dart' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

# What the build is made of. A tree already stamped with this is left alone.
stamp() {
  {
    echo "$VERSION"
    cat "$PATCHES"/*.patch
  } | sha256sum | cut -d' ' -f1
}

# Upstream's release, fetched once into a cache of our own and checked against
# the source the patches were cut from.
upstream() {
  if [[ ! -d $UPSTREAM ]]; then
    echo "fetching xterm $VERSION" >&2
    PUB_CACHE="$TMP/fetch" dart pub cache add xterm --version "$VERSION" >&2
    local got
    got=$(find "$TMP/fetch" -type d -name "xterm-$VERSION" -print -quit)
    [[ -n $got ]] || die "dart pub cache add left no xterm-$VERSION behind"
    cp -r "$got" "$UPSTREAM"
    chmod -R u+w "$UPSTREAM"
  fi

  local got
  got=$(lib_sha "$UPSTREAM/lib")
  [[ $got == "$LIB_SHA" ]] ||
    die "xterm $VERSION is not the source the patches were cut from"$'\n'"  want $LIB_SHA"$'\n'"  got  $got"
}

# Upstream plus the patches, under TMP and never in place, so a patch that
# fails leaves no half-applied tree behind for the next build to no-op over.
materialise() {
  local into=$TMP/$1 drop=${2:-} patch
  upstream
  cp -r "$UPSTREAM" "$into"
  chmod -R u+w "$into"
  for patch in "$PATCHES"/*.patch; do
    if [[ -n $drop && $(basename "$patch" .patch) == "$drop" ]]; then continue; fi
    git -C "$into" apply -p1 --whitespace=nowarn "$patch" ||
      die "$(basename "$patch") does not apply${drop:+ without $drop; they are one behaviour}"
  done
  # A patch that applied to nothing is the failure this whole arrangement is
  # most likely to hide, so the tree is proven to have moved off upstream.
  ! diff -rq --exclude='.*' "$UPSTREAM" "$into" >/dev/null ||
    die "the patches applied but changed nothing"
}

install_tree() {
  materialise product "${1:-}"
  rm -rf "$BUILD"
  mv "$TMP/product" "$BUILD"
}

build() {
  local want
  want=$(stamp)
  [[ -f $BUILD/.stamp && $(cat "$BUILD/.stamp") == "$want" ]] && return 0

  install_tree
  echo "$want" >"$BUILD/.stamp"
  echo "built xterm $VERSION plus ${#CONCERNS[@]} patches into .dart_tool/xterm"
}

verify() {
  [[ -d $BUILD ]] || build
  materialise fresh
  if ! diff -ruN --exclude='.*' "$TMP/fresh" "$BUILD" >/dev/null; then
    echo ".dart_tool/xterm is not upstream plus the patches:" >&2
    # head closes the pipe on the 40th line, which is not this script failing.
    diff -ruN --exclude='.*' "$TMP/fresh" "$BUILD" | head -40 >&2 || true
    die "write the difference down with \`just xterm-patches\`, or throw it away with \`rm -rf .dart_tool/xterm\`"
  fi
  echo ".dart_tool/xterm is xterm $VERSION plus the patches, and nothing else"
}

# git does the hunk splitting: a tree of upstream, one commit per behaviour,
# and the diff of each commit is that behaviour's patch. `git diff` rather than
# format-patch, so no commit id or date lands in the file and regenerating an
# unchanged package rewrites nothing.
generate() {
  local work=$TMP/series
  upstream
  mkdir -p "$work"
  cp -r "$UPSTREAM/lib" "$work/lib"
  chmod -R u+w "$work/lib"

  local git=(git -C "$work" -c user.email=x -c user.name=x -c commit.gpgsign=false)
  "${git[@]}" init -q
  "${git[@]}" add -A
  "${git[@]}" commit -qm "xterm $VERSION"

  # Written aside and swapped in at the end: a series that cannot regenerate
  # must not take the committed one with it on the way out.
  local out=$TMP/patches
  mkdir -p "$out"

  local entry name subject paths path
  for entry in "${CONCERNS[@]}"; do
    IFS='|' read -r name subject paths <<<"$entry"
    for path in $paths; do
      [[ -f $BUILD/$path ]] || die "$path is in the series but not in .dart_tool/xterm"
      mkdir -p "$work/$(dirname "$path")"
      cp "$BUILD/$path" "$work/$path"
    done
    "${git[@]}" add -A
    "${git[@]}" commit -qm "$subject" >/dev/null ||
      die "nothing changed for $name; .dart_tool/xterm is missing that patch, so \`just xterm-build\` first"
    {
      echo "# $subject"
      echo "#"
      echo "# Against xterm $VERSION. Regenerate with \`just xterm-patches\`."
      echo
      "${git[@]}" diff --no-color --no-ext-diff HEAD~1 HEAD
    } >"$out/$name.patch"
    echo "  $name.patch"
  done

  rm -rf "$PATCHES"
  mv "$out" "$PATCHES"

  # An edit no patch claims would vanish from the series, so the series is only
  # honest if it still reproduces what it was read from.
  verify
}

# 03, 06 and 07 add API that dazzle calls (keyboardOnTap in shell_terminal.dart,
# onReport and colors in shell_sessions.dart), so dropping any of them wants
# those call sites edited too. 06 and 07 are one behaviour split across an
# ownership line — the colour reply is answered in 07 and emitted in 06 — so
# neither compiles without the other. 04 drops clean for a build: the token API
# it adds is only read by test/terminal_token_test.dart. 01, 02 and 05 change
# behaviour and no surface.
without() {
  local drop=${1:-}
  [[ -n $drop ]] || die "usage: xterm-patches.sh without <patch-name>"
  [[ -f $PATCHES/$drop.patch ]] ||
    die "no patch $drop; have: $(cd "$PATCHES" && ls ./*.patch | sed -e 's|\./||' -e 's/\.patch$//' | tr '\n' ' ')"

  install_tree "$drop"
  # A stamp no build can match, so the next one puts the patch back.
  echo "without-$drop" >"$BUILD/.stamp"
  echo "built xterm $VERSION without $drop; \`just xterm-build\` puts it back"
}

case "${1:-build}" in
build) build ;;
generate) generate ;;
verify) verify ;;
without) without "${2:-}" ;;
*) die "usage: xterm-patches.sh [build|generate|verify|without <patch-name>]" ;;
esac
