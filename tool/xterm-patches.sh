#!/usr/bin/env bash
# The fork in packages/xterm is the working copy: the analyzer, the IDE and hot
# reload all read it, so it stays on disk and stays editable. The patches beside
# it are derived from it and carry the provenance the tree cannot: what upstream
# 4.0.0 said, and what we changed line by line.
#
#   generate  rewrite the series from the current tree
#   verify    apply the series to a pristine 4.0.0 and prove it reproduces the tree
#
# Dropping one patch and running the series is how a behaviour gets bisected
# back to the change that introduced it.
set -euo pipefail

readonly UPSTREAM_VERSION=4.0.0
# sha256 over the sorted sha256 of every .dart file under lib/, so a rebuilt or
# re-fetched cache is checked against the source the series was cut from.
readonly UPSTREAM_LIB_SHA=12bd4729255b42339be8858b09a320c167556c8429b171bce627a7c27461126a

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PKG="$ROOT/packages/xterm"
readonly PATCHES="$PKG/patches"

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
  "03-keyboard-on-tap|a tap on the terminal need not raise the IME|lib/src/terminal_view.dart"
  "04-touch-selection|a touch selection anchors at pointer-down and takes tokens whole|lib/src/ui/gesture/gesture_handler.dart lib/src/ui/render.dart lib/src/core/buffer/token.dart lib/src/core/buffer/buffer.dart lib/core.dart"
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

# The lockfile resolves xterm from packages/xterm, so nothing guarantees the
# hosted release is still in the cache. Fetch it when it is gone.
upstream_dir() {
  local dir="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev/xterm-$UPSTREAM_VERSION"
  if [[ ! -d $dir ]]; then
    echo "fetching xterm $UPSTREAM_VERSION" >&2
    dart pub cache add xterm --version "$UPSTREAM_VERSION" >&2
  fi
  [[ -d $dir ]] || die "no pristine xterm $UPSTREAM_VERSION at $dir"

  local got
  got=$(lib_sha "$dir/lib")
  [[ $got == "$UPSTREAM_LIB_SHA" ]] ||
    die "pristine xterm $UPSTREAM_VERSION does not match the pinned hash"$'\n'"  want $UPSTREAM_LIB_SHA"$'\n'"  got  $got"

  echo "$dir"
}

# A git tree holding pristine lib/, one commit per behaviour. git does the hunk
# splitting and guarantees the series applies in order.
build_series() {
  local upstream=$1 work=$2

  mkdir -p "$work"
  cp -r "$upstream/lib" "$work/lib"
  chmod -R u+w "$work/lib"

  git -C "$work" init -q
  git -C "$work" add -A
  git -C "$work" -c user.email=x -c user.name=x -c commit.gpgsign=false commit -qm "xterm $UPSTREAM_VERSION"

  local entry name subject paths path
  for entry in "${CONCERNS[@]}"; do
    IFS='|' read -r name subject paths <<<"$entry"
    for path in $paths; do
      [[ -f $PKG/$path ]] || die "$path is in the series but not in the tree"
      mkdir -p "$work/$(dirname "$path")"
      cp "$PKG/$path" "$work/$path"
    done
    git -C "$work" add -A
    git -C "$work" -c user.email=x -c user.name=x -c commit.gpgsign=false commit -qm "$subject"
  done
}

generate() {
  local upstream work
  upstream=$(upstream_dir)
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT

  build_series "$upstream" "$work"

  rm -rf "$PATCHES"
  mkdir -p "$PATCHES"

  # `git diff` of each step rather than format-patch: no commit id, no date, so
  # regenerating an unchanged tree rewrites nothing.
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

  # Anything changed in lib/ that no patch claims would silently vanish from the
  # series, so the series is only honest if it reproduces the tree exactly.
  rm -rf "$work"
  verify
}

verify() {
  local upstream work
  upstream=$(upstream_dir)
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT

  cp -r "$upstream/lib" "$work/lib"
  chmod -R u+w "$work/lib"

  local patch
  for patch in "$PATCHES"/*.patch; do
    [[ -f $patch ]] || die "no patches in $PATCHES; run \`just xterm-patches\`"
    (cd "$work" && git apply -p1 --whitespace=nowarn "$patch") ||
      die "$(basename "$patch") does not apply"
  done

  if ! diff -ruN --exclude='.*' "$work/lib" "$PKG/lib" >/dev/null; then
    echo "the series does not reproduce packages/xterm/lib:" >&2
    diff -ruN --exclude='.*' "$work/lib" "$PKG/lib" | head -40 >&2
    die "run \`just xterm-patches\` to rewrite it from the tree"
  fi
  echo "series reproduces packages/xterm/lib from xterm $UPSTREAM_VERSION"
}

# Rebuild the fork from the series with one patch left out, so a behaviour can
# be tried without the change that is suspected of causing it.
#
# 03 and 06 add API that dazzle calls (keyboardOnTap in shell_terminal.dart,
# onReport in shell_sessions.dart), so dropping either wants those call sites
# edited too. 04 drops clean for a build: the token API it adds is only read by
# test/terminal_token_test.dart. 01, 02 and 05 change behaviour and no surface.
without() {
  local drop=${1:-}
  [[ -n $drop ]] || die "usage: xterm-patches.sh without <patch-name>"
  local target="$PATCHES/$drop.patch"
  [[ -f $target ]] || die "no patch $drop; have: $(cd "$PATCHES" && ls *.patch | sed 's/\.patch$//' | tr '\n' ' ')"

  # The way back is `git checkout -- packages/xterm/lib`, which only works if
  # there is nothing of your own in there to lose. This checkout is shared.
  if [[ -n $(git -C "$ROOT" status --porcelain -- packages/xterm/lib) ]]; then
    die "packages/xterm/lib has uncommitted changes; commit or stash them first"
  fi

  local upstream work
  upstream=$(upstream_dir)
  work=$(mktemp -d)
  trap 'rm -rf "${work:-}"' EXIT

  cp -r "$upstream/lib" "$work/lib"
  chmod -R u+w "$work/lib"

  local patch
  for patch in "$PATCHES"/*.patch; do
    [[ $patch == "$target" ]] && continue
    (cd "$work" && git apply -p1 --whitespace=nowarn "$patch") ||
      die "$(basename "$patch") does not apply without $drop; they are one concern"
  done

  rm -rf "$PKG/lib"
  cp -r "$work/lib" "$PKG/lib"
  echo "packages/xterm/lib rebuilt without $drop"
  echo "restore with: git checkout -- packages/xterm/lib"
}

case "${1:-verify}" in
generate) generate ;;
verify) verify ;;
without) without "${2:-}" ;;
*) die "usage: xterm-patches.sh [generate|verify|without <patch-name>]" ;;
esac
