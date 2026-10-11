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

Every build and every install runs under build/deploy/lock, and each run pins
one commit when it takes the lock, so a run queued behind another builds what
HEAD is once its turn comes.

  stamp [rev]                 <name> <code> <sha> of rev, HEAD by default
  build [rev]                 the release apk of rev, verified; prints its path
  once [device...]            install on the handsets named, or on every one
                              attached; a handset at or past HEAD is left alone
  watch [device...]           once now, then once more each time HEAD moves.
                              HEAD must sit still for ten seconds first, so a
                              burst of commits builds once. A commit landing
                              mid-build drops that build for the new HEAD; one
                              landing mid-install waits for the install. Each
                              build rings and asks here; an n shelves it,
                              silence for thirty seconds installs. A commit
                              that fails to build is not retried.
EOF
}

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PKG=dev.luisnquin.upgrade
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

head_rev() {
  git -C "$ROOT" rev-parse --verify "${1:-HEAD}^{commit}"
}

lock() {
  mkdir -p "$OUT"
  exec 9>"$OUT/lock"
  flock -n 9 || {
    say "another deploy holds $OUT/lock; waiting for it" >&2
    flock 9
  }
}

stamp() {
  local rev=$1 name code sha
  name=$(git -C "$ROOT" show "$rev:pubspec.yaml" | sed -n 's/^version:[[:space:]]*\([^+[:space:]]\{1,\}\).*$/\1/p')
  [[ -n $name ]] || die "pubspec.yaml at $rev has no 'version:' line"
  code=$(git -C "$ROOT" rev-list --count "$rev")
  sha=$(git -C "$ROOT" rev-parse --short "$rev")
  echo "$name $code $sha"
}

build() {
  local rev=$1 name code sha
  read -r name code sha <<<"$(stamp "$rev")"
  local apk="$OUT/upgrade-$name-$code-$sha.apk"
  if [[ -f $apk ]]; then
    echo "$apk"
    return 0
  fi

  local tools="${ANDROID_HOME:?run inside the nix dev shell}/build-tools/37.0.0"
  command -v flutter >/dev/null || die "no flutter on PATH; run inside the nix dev shell"
  mkdir -p "$TREE/.dart_tool"
  find "$TREE" -mindepth 1 -maxdepth 1 ! -name .dart_tool ! -name build -exec rm -rf {} +
  git -C "$ROOT" archive "$rev" | tar -x -C "$TREE"

  local built="$TREE/build/app/outputs/flutter-apk/app-release.apk"
  rm -f "$built"
  # AGP's incremental compressReleaseAssets fails with "already contains entry" when the
  # asset set changes between runs; packing from scratch costs seconds.
  rm -rf "$TREE/build/app/intermediates/compressed_assets"
  # 9>&-: a daemon the build leaves behind must not keep holding the lock.
  (
    cd "$TREE" &&
      just pub-build && flutter pub get && just gen &&
      UPGRADE_BUILD=$sha just apk-release "$name" "$code"
  ) >&2 9>&- || die "the build of $name+$code ($sha) failed"
  [[ -f $built ]] || die "the build of $name+$code ($sha) left no apk"

  local badged cert
  badged=$("$tools/aapt2" dump badging "$built" | sed -n "1s/.*versionCode='\([0-9]*\)'.*/\1/p")
  [[ $badged == "$code" ]] || die "apk reports versionCode $badged, HEAD is $code"
  cert=$("$tools/apksigner" verify --print-certs "$built" | awk '/certificate SHA-256 digest:/ {print $NF; exit}')
  [[ $cert == "$CERT" ]] || die "apk signed by $cert, not the key the handsets trust"

  cp "$built" "$apk"
  ls -t "$OUT"/upgrade-*.apk | tail -n +3 | xargs -r rm -f
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

recorded() {
  awk -F'\t' -v l="$1" '$1 == l { print $2, $3 }' "$OUT/deployed" 2>/dev/null || true
}

record() {
  local f="$OUT/deployed"
  {
    grep -v "^$1	" "$f" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  } >"$f.tmp"
  mv "$f.tmp" "$f"
}

kill_tree() {
  local child
  for child in $(pgrep -P "$1"); do
    kill_tree "$child"
  done
  kill "$1" 2>/dev/null || true
}

once() {
  local ask=$1 rev=$2
  shift 2

  local targets
  targets=$(resolve "$@") || return 1
  if [[ -z $targets ]]; then
    local idle
    idle=$(handsets | awk -F'\t' '$2 !~ /^attached\// && $4 > 0 { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
    [[ -n $idle ]] || idle="none it can reach"
    warn "no handset attached; name one to dial it: $idle"
    return 1
  fi

  # Under the lock: a deploy queued behind another must see what that one installed.
  lock
  [[ -n $rev ]] || rev=$(head_rev)
  [[ $(head_rev) == "$rev" ]] || return 2
  local name code sha
  read -r name code sha <<<"$(stamp "$rev")"

  local pending=() label serial pkg have rcode rsha
  while IFS=$'\t' read -r label serial; do
    pkg=$(dumpsys "$serial")
    have=$(version_code "$pkg")
    if [[ -n $have && $have -ge $code ]]; then
      read -r rcode rsha <<<"$(recorded "$label")"
      if [[ $have == "$code" && $rcode == "$code" && $rsha != "$sha" ]]; then
        warn "$label holds $code as $rsha, HEAD is $code as $sha: history was rewritten under the same count, and only an uninstall, which wipes its data, lands it"
      else
        say "$label carries $have, HEAD is $code: nothing to do"
      fi
      continue
    fi
    pending+=("$label	$serial	${have:-none}")
  done <<<"$targets"
  [[ ${#pending[@]} -gt 0 ]] || return 0

  local apk
  if [[ $ask != ask ]]; then
    apk=$(build "$rev") || return 3
  else
    local onto asking building answer="$OUT/answer" log="$OUT/build.log" path="$OUT/apk.path"
    onto=$(printf '%s\n' "${pending[@]}" | cut -f1 | paste -sd' ')
    rm -f "$answer" "$path"
    say "building $name+$code ($sha); its log is $log"
    printf '\a'
    (
      ans=""
      read -r -t 30 -p "deploy: $name+$code ($sha) onto $onto. Install? [Y/n, yes in 30s] " ans </dev/tty || echo
      printf '%s\n' "$ans" >"$answer"
    ) &
    asking=$!
    build "$rev" >"$path" 2>"$log" &
    building=$!
    while kill -0 "$building" 2>/dev/null; do
      if [[ $(head_rev) != "$rev" ]]; then
        kill_tree "$building"
        kill_tree "$asking"
        wait "$building" "$asking" 2>/dev/null || true
        echo
        say "HEAD moved past $sha; dropped its build"
        return 2
      fi
      sleep 2
    done
    if ! wait "$building"; then
      kill_tree "$asking"
      echo
      tail -n 20 "$log" >&2
      return 3
    fi
    apk=$(<"$path")
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
    record "$label" "$code" "$sha"
    say "$label: $have -> $name+$code ($sha), $(grep -oE 'firstInstallTime=[^ ]+ [^ ]+' <<<"$pkg" | head -1)"
  done
  return $failed
}

settle() {
  local was=$1 now
  while :; do
    sleep 10
    now=$(head_rev)
    [[ $now == "$was" ]] && break
    was=$now
  done
  echo "$was"
}

watch() {
  local seen="" broken="" head rc
  say "watching HEAD of $ROOT for ${*:-every handset attached}; ^C stops"
  while :; do
    head=$(head_rev)
    if [[ $head == "$seen" || $head == "$broken" ]]; then
      sleep 5
      continue
    fi
    head=$(settle "$head")
    rc=0
    (once ask "$head" "$@") || rc=$?
    case $rc in
    0) seen=$head ;;
    2) ;;
    3)
      broken=$head
      warn "$(git -C "$ROOT" rev-parse --short "$head") does not build; waiting for HEAD to move"
      ;;
    *)
      warn "that round failed; retrying the current commit in 30s"
      sleep 30
      ;;
    esac
  done
}

case "${1:-}" in
stamp) stamp "$(head_rev "${2:-}")" ;;
build)
  rev=$(head_rev "${2:-}")
  lock
  build "$rev"
  ;;
once) once no "" "${@:2}" ;;
watch) watch "${@:2}" ;;
-h | --help)
  usage
  ;;
*)
  usage >&2
  exit 1
  ;;
esac
