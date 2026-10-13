#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
pub-patches.sh <package> [command]

An upstream package, from pub or from a nix store pin, plus the patches under
packages/<name>/patches, materialised under .dart_tool.

  build                                  apply the series, if it or the version moved
  verify                                 prove the series reproduces the build exactly
  without <patch>                        apply the series with one patch dropped
  generate                               rewrite the series from edits to the build
  generate <patch> <subject> <path>...   the same, with one concern added

A patch declares itself: `# <subject>` on the first line, its files in the diff
under it, its place in the series in its NN- prefix. A build leaves a tree whose
series it already holds alone, so an edit to .dart_tool/<package> survives until
`generate` writes it down or `rm -rf` drops it.

A whole file is copied per concern, so a file belongs to exactly one of them.
EOF
}

pin() {
  case "$1" in
  dart_mosh) VERSION=0.0.4 RECIPE=mosh ;;
  dartssh2) VERSION=4.0.0 RECIPE=ssh ;;
  flterm)
    VERSION=${LIBGHOSTTY_REV:?run inside the nix dev shell} RECIPE=flterm
    SRC=${LIBGHOSTTY_SRC:?run inside the nix dev shell}/packages/flterm
    ;;
  *) die "no package $1; have: dart_mosh dartssh2 flterm" ;;
  esac
}

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

die() {
  echo "${PACKAGE:-pub}-patches: $*" >&2
  exit 1
}

names() {
  local patch
  for patch in "$PATCHES"/*.patch; do
    [[ -e $patch ]] || continue
    basename "$patch" .patch
  done
}

subject_of() {
  sed -n '1s/^# //p' "$PATCHES/$1.patch"
}

paths_of() {
  sed -n 's|^+++ b/||p' "$PATCHES/$1.patch"
}

stamp() {
  {
    echo "$VERSION"
    cat "$PATCHES"/*.patch
  } | sha256sum | cut -d' ' -f1
}

upstream() {
  [[ -d $UPSTREAM ]] && return 0
  if [[ -z ${SRC:-} ]]; then
    dart pub unpack "$PACKAGE@$VERSION" --no-resolve --output="$ROOT/.dart_tool" >&2
    return
  fi
  cp -r "$SRC" "$TMP/upstream"
  chmod -R u+w "$TMP/upstream"
  mv -T "$TMP/upstream" "$UPSTREAM" 2>/dev/null || [[ -d $UPSTREAM ]]
}

assemble() {
  local drop=${1:-} patch
  upstream
  rm -rf "$TMP/tree"
  cp -r "$UPSTREAM" "$TMP/tree"
  for patch in "$PATCHES"/*.patch; do
    if [[ -n $drop && $(basename "$patch" .patch) == "$drop" ]]; then continue; fi
    git -C "$TMP/tree" apply -p1 --whitespace=nowarn "$patch" ||
      die "$(basename "$patch") does not apply${drop:+ without $drop; they are one behaviour}"
  done
  ! diff -rq --exclude='.*' "$UPSTREAM" "$TMP/tree" >/dev/null ||
    die "the patches applied but changed nothing"
}

install_tree() {
  assemble "${1:-}"
  rm -rf "$BUILD"
  mv "$TMP/tree" "$BUILD"
}

build() {
  local want
  want=$(stamp)
  [[ -f $BUILD/.stamp && $(cat "$BUILD/.stamp") == "$want" ]] && return 0

  install_tree
  echo "$want" >"$BUILD/.stamp"
  echo "built $PACKAGE $VERSION plus $(names | wc -l) patches into .dart_tool/$PACKAGE"
}

verify() {
  [[ -d $BUILD ]] || build
  assemble
  if ! diff -ruN --exclude='.*' "$TMP/tree" "$BUILD" >/dev/null; then
    echo ".dart_tool/$PACKAGE is not upstream plus the patches:" >&2
    diff -ruN --exclude='.*' "$TMP/tree" "$BUILD" | head -40 >&2 || true
    die "write the difference down with \`just $RECIPE-patches\`, or throw it away with \`rm -rf .dart_tool/$PACKAGE\`"
  fi
  echo ".dart_tool/$PACKAGE is $PACKAGE $VERSION plus the patches, and nothing else"
}

generate() {
  local added=${1:-} added_subject=${2:-}
  [[ $# -lt 3 ]] || shift 2
  local added_paths=("$@")
  [[ -z $added || ${#added_paths[@]} -gt 0 ]] ||
    die "usage: pub-patches.sh $PACKAGE generate <patch> <subject> <path>..."
  [[ -z $added || ! -f $PATCHES/$added.patch ]] || die "$added is already in the series"

  local work=$TMP/series out=$TMP/patches
  upstream
  mkdir -p "$work" "$out"
  cp -r "$UPSTREAM/lib" "$work/lib"

  # Hooks off too, from hooksPath and hook.* config: a throwaway repo inherits the global
  # ones, which would judge upstream's own source as though this commit had written it.
  local git=(git -C "$work" -c user.email=x -c user.name=x -c commit.gpgsign=false -c core.hooksPath=/dev/null)
  local event
  for event in pre-commit prepare-commit-msg commit-msg post-commit; do
    git+=(-c "hook.$event.enabled=false")
  done
  "${git[@]}" init -q
  "${git[@]}" add -A
  "${git[@]}" commit -qm "$PACKAGE $VERSION"

  local ordered name subject paths path
  mapfile -t ordered < <(
    names
    [[ -z $added ]] || echo "$added"
  )
  mapfile -t ordered < <(printf '%s\n' "${ordered[@]}" | sort)

  for name in "${ordered[@]}"; do
    if [[ $name == "$added" ]]; then
      subject=$added_subject
      paths=("${added_paths[@]}")
    else
      subject=$(subject_of "$name")
      mapfile -t paths < <(paths_of "$name")
    fi
    for path in "${paths[@]}"; do
      [[ -f $BUILD/$path ]] || die "$path is in $name but not in .dart_tool/$PACKAGE"
      mkdir -p "$work/$(dirname "$path")"
      cp "$BUILD/$path" "$work/$path"
    done
    "${git[@]}" add -A
    "${git[@]}" commit -qm "$subject" >/dev/null ||
      die "nothing changed for $name; .dart_tool/$PACKAGE is missing that patch, so \`just $RECIPE-build\` first"
    {
      echo "# $subject"
      echo "#"
      echo "# Against $PACKAGE $VERSION. Regenerate with \`just $RECIPE-patches\`."
      echo
      "${git[@]}" diff --no-color --no-ext-diff HEAD~1 HEAD
    } >"$out/$name.patch"
    echo "  $name.patch"
  done

  rm -rf "$PATCHES"
  mv "$out" "$PATCHES"

  verify
}

without() {
  local drop=${1:-}
  [[ -n $drop ]] || die "usage: pub-patches.sh $PACKAGE without <patch>"
  [[ -f $PATCHES/$drop.patch ]] || die "no patch $drop; have: $(names | tr '\n' ' ')"

  install_tree "$drop"
  echo "without-$drop" >"$BUILD/.stamp"
  echo "built $PACKAGE $VERSION without $drop; \`just $RECIPE-build\` puts it back"
}

PACKAGE=${1:-}
case "$PACKAGE" in
-h | --help)
  usage
  exit 0
  ;;
'')
  usage >&2
  exit 1
  ;;
esac
pin "$PACKAGE"

PATCHES="$ROOT/packages/$PACKAGE/patches"
BUILD="$ROOT/.dart_tool/$PACKAGE"
UPSTREAM="$ROOT/.dart_tool/$PACKAGE-$VERSION"

case "${2:-build}" in
build) build ;;
verify) verify ;;
without) without "${3:-}" ;;
generate) generate "${@:3}" ;;
*)
  usage >&2
  exit 1
  ;;
esac
