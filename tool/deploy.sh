#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
deploy.sh <command> [args]

A release build of HEAD on the handsets in reach. The build number is the
commit count at HEAD, so every commit is a release and every handset that
holds a commit holds it under the same number. HEAD is exported on its own
under build/deploy/tree, so nothing another session left in the working tree
can ride along; the export keeps .dart_tool and build/ between runs for the
caches. The apk must be signed by ~/.android/debug.keystore: one from any
other key can only land by uninstalling, and the handsets hold real data.

  stamp                       <name> <code> <sha> of HEAD
  build                       the release apk of HEAD, verified; prints its path
  once [device...]            install on the handsets named, or on every one
                              attached; a handset at or past HEAD is left alone
  watch [device...]           once now, then once more each time HEAD moves.
                              Each new HEAD rings and asks here while it
                              builds; an n shelves it, silence for thirty
                              seconds installs.
EOF
}

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PKG=dev.luisnquin.dazzle
readonly CERT=d6b7cdfb8d0a5c0017e317b7db27f3fb3ce0b3f650f28ca6b989c4582f5d7e5e
readonly OUT="$ROOT/build/deploy"
readonly TREE="$OUT/tree"

if [[ -t 2 ]]; then
  readonly RED=$'\033[1;31m' OFF=$'\033[0m'
else
  readonly RED='' OFF=''
fi

warn() {
  printf '%sdeploy: %s%s\n' "$RED" "$*" "$OFF" >&2
}

die() {
  warn "$*"
  exit 1
}

say() {
  echo "deploy: $*"
}

stamp() {
  local name code sha
  name=$(git -C "$ROOT" show HEAD:pubspec.yaml | sed -n 's/^version:[[:space:]]*\([^+[:space:]]\{1,\}\).*$/\1/p')
  [[ -n $name ]] || die "pubspec.yaml at HEAD has no 'version:' line"
  code=$(git -C "$ROOT" rev-list --count HEAD)
  sha=$(git -C "$ROOT" rev-parse --short HEAD)
  echo "$name $code $sha"
}

build() {
  local name code sha
  read -r name code sha <<<"$(stamp)"
  local apk="$OUT/dazzle-$name-$code-$sha.apk"
  if [[ -f $apk ]]; then
    echo "$apk"
    return 0
  fi

  local tools="${ANDROID_HOME:?run inside the nix dev shell}/build-tools/37.0.0"
  command -v flutter >/dev/null || die "no flutter on PATH; run inside the nix dev shell"
  mkdir -p "$TREE/.dart_tool"
  find "$TREE" -mindepth 1 -maxdepth 1 ! -name .dart_tool ! -name build -exec rm -rf {} +
  git -C "$ROOT" archive HEAD | tar -x -C "$TREE"

  local built="$TREE/build/app/outputs/flutter-apk/app-release.apk"
  rm -f "$built"
  (
    cd "$TREE" &&
      just pub-build && flutter pub get && just gen &&
      DAZZLE_BUILD=$sha just apk-release "$name" "$code"
  ) >&2 || die "the build of $name+$code ($sha) failed"
  [[ -f $built ]] || die "the build of $name+$code ($sha) left no apk"

  local badged cert
  badged=$("$tools/aapt2" dump badging "$built" | sed -n "1s/.*versionCode='\([0-9]*\)'.*/\1/p")
  [[ $badged == "$code" ]] || die "apk reports versionCode $badged, HEAD is $code"
  cert=$("$tools/apksigner" verify --print-certs "$built" | awk '/certificate SHA-256 digest:/ {print $NF; exit}')
  [[ $cert == "$CERT" ]] || die "apk signed by $cert, not the key the handsets trust"

  rm -f "$OUT"/dazzle-*.apk
  cp "$built" "$apk"
  echo "$apk"
}

handsets() {
  phone device list --json |
    jq -r '.[] | select(.platform == "android") | [.label, .reach, (.serial // ""), (.endpoints | length)] | @tsv'
}

serial_of() {
  awk -F'\t' -v l="$1" '$1 == l && $2 ~ /^attached\// { print $3 }'
}

resolve() {
  local rows label serial
  rows=$(handsets)
  if [[ $# -eq 0 ]]; then
    awk -F'\t' '$2 ~ /^attached\// && $3 != "" { print $1 "\t" $3 }' <<<"$rows"
    return 0
  fi
  for label in "$@"; do
    grep -q "^$label	" <<<"$rows" ||
      die "no handset $label; phone knows: $(cut -f1 <<<"$rows" | paste -sd' ')"
    serial=$(serial_of "$label" <<<"$rows")
    if [[ -z $serial ]]; then
      phone device connect "$label" >&2 || true
      serial=$(handsets | serial_of "$label")
    fi
    [[ -n $serial ]] || die "$label: no transport after connect"
    printf '%s\t%s\n' "$label" "$serial"
  done
}

dumpsys() {
  adb -s "$1" shell dumpsys package "$PKG" 2>/dev/null || true
}

version_code() {
  sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' <<<"$1" | head -1
}

updated_at() {
  sed -n 's/.*lastUpdateTime=//p' <<<"$1" | head -1
}

once() {
  local ask=$1
  shift
  local name code sha
  read -r name code sha <<<"$(stamp)"

  local targets
  targets=$(resolve "$@") || return 1
  if [[ -z $targets ]]; then
    local idle
    idle=$(handsets | awk -F'\t' '$2 !~ /^attached\// && $4 > 0 { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
    [[ -n $idle ]] || idle="none it can reach"
    warn "no handset attached; name one to dial it: $idle"
    return 1
  fi

  local pending=() label serial pkg have
  while IFS=$'\t' read -r label serial; do
    pkg=$(dumpsys "$serial")
    have=$(version_code "$pkg")
    if [[ -n $have && $have -ge $code ]]; then
      say "$label carries $have, HEAD is $code: nothing to do"
      continue
    fi
    pending+=("$label	$serial	${have:-none}")
  done <<<"$targets"
  [[ ${#pending[@]} -gt 0 ]] || return 0

  mkdir -p "$OUT"
  exec 9>"$OUT/lock"
  flock -n 9 || {
    say "another deploy holds $OUT/lock; waiting for it"
    flock 9
  }

  local apk
  if [[ $ask != ask ]]; then
    apk=$(build) || return 1
  else
    local onto asking answer="$OUT/answer" log="$OUT/build.log"
    onto=$(printf '%s\n' "${pending[@]}" | cut -f1 | paste -sd' ')
    rm -f "$answer"
    say "building $name+$code ($sha); its log is $log"
    printf '\a'
    (
      ans=""
      read -r -t 30 -p "deploy: $name+$code ($sha) onto $onto. Install? [Y/n, yes in 30s] " ans </dev/tty || echo
      printf '%s\n' "$ans" >"$answer"
    ) &
    asking=$!
    if ! apk=$(build 2>"$log"); then
      kill "$asking" 2>/dev/null || true
      echo
      tail -n 20 "$log" >&2
      return 1
    fi
    wait "$asking" || true
    [[ $(cat "$answer" 2>/dev/null) != [nN]* ]] || {
      say "left on the shelf: $apk"
      return 0
    }
  fi

  local line was now failed=0
  for line in "${pending[@]}"; do
    IFS=$'\t' read -r label serial have <<<"$line"
    was=$(updated_at "$(dumpsys "$serial")")
    if ! phone app install -t "$label" "$apk"; then
      warn "$label: install failed"
      failed=1
      continue
    fi
    pkg=$(dumpsys "$serial")
    now=$(version_code "$pkg")
    if [[ $now != "$code" ]]; then
      warn "$label: still on versionCode ${now:-none} after install"
      failed=1
      continue
    fi
    if [[ -n $was && $(updated_at "$pkg") == "$was" ]]; then
      warn "$label: lastUpdateTime still $was, nothing was replaced"
      failed=1
      continue
    fi
    say "$label: $have -> $name+$code ($sha), $(grep -oE 'firstInstallTime=[^ ]+ [^ ]+' <<<"$pkg" | head -1)"
  done
  return $failed
}

watch() {
  local seen="" head
  say "watching HEAD of $ROOT for ${*:-every handset attached}; ^C stops"
  while :; do
    head=$(git -C "$ROOT" rev-parse HEAD)
    if [[ $head != "$seen" ]]; then
      if (once ask "$@"); then
        seen=$head
      else
        warn "that round failed; retrying the current commit in 30s"
        sleep 30
        continue
      fi
    fi
    sleep 5
  done
}

case "${1:-}" in
stamp) stamp ;;
build) build ;;
once) once no "${@:2}" ;;
watch) watch "${@:2}" ;;
-h | --help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
