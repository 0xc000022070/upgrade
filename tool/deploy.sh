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
                              On a terminal a chef cooks it in front of you;
                              DEPLOY_PLAIN=1 keeps the plain log.
EOF
}

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PKG=dev.luisnquin.upgrade
readonly CERT=d6b7cdfb8d0a5c0017e317b7db27f3fb3ce0b3f650f28ca6b989c4582f5d7e5e
readonly OUT="$ROOT/build/deploy"
readonly TREE="$OUT/tree"

source "$ROOT/tool/chef.sh"

if [[ -t 2 ]]; then
  readonly RED=$'\033[1;31m' OFF=$'\033[0m'
else
  readonly RED='' OFF=''
fi

warn() {
  chef_clear
  printf '%sdeploy: %s%s\n' "$RED" "$*" "$OFF" >&2
}

die() {
  warn "$*"
  exit 1
}

say() {
  chef_clear
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
      nix develop "git+file://$ROOT?rev=$rev" -c env UPGRADE_BUILD="$sha" bash -c \
        'just pub-build && flutter pub get && just gen && just apk-release "$1" "$2"' _ "$name" "$code"
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
    local onto building built="" answer="" log="$OUT/build.log" path="$OUT/apk.path"
    local eta started=$SECONDS waited tick=0 key step="" bubble pose
    onto=$(printf '%s\n' "${pending[@]}" | cut -f1 | paste -sd' ')
    eta=$(cat "$OUT/build.seconds" 2>/dev/null || true)
    rm -f "$path"
    say "building $name+$code ($sha); its log is $log"
    printf '\a'
    build "$rev" >"$path" 2>"$log" &
    building=$!
    chef_open
    trap 'kill_tree "$building"; chef_close; exit 130' INT TERM
    trap chef_close EXIT
    [[ -n $CHEF_TTY ]] || answer=y
    ((CHEF_ON)) || [[ -n $answer ]] || say "$name+$code ($sha) onto $onto. Install? [Y/n, yes in 30s]"
    while :; do
      waited=$((SECONDS - started))
      ((waited < 30)) || : "${answer:=y}"
      if ((tick % 8 == 0)) && [[ $(head_rev) != "$rev" ]]; then
        kill_tree "$building"
        wait "$building" 2>/dev/null || true
        chef_end toss "$tick" "New HEAD! $sha goes in the bin, chef starts over."
        say "HEAD moved past $sha; dropped its build"
        return 2
      fi
      if [[ -z $built ]] && ! kill -0 "$building" 2>/dev/null; then
        built=0
        wait "$building" || built=$?
        ((built != 0)) || ((waited < 20)) || echo "$waited" >"$OUT/build.seconds"
      fi
      [[ -n $built ]] && { ((built != 0)) || [[ -n $answer ]]; } && break

      ((tick % 4)) || step=$(tail -c 400 "$log" 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; /^[[:space:]]*$/d' | tail -n 1)
      pose=stir
      [[ -n $eta ]] && ((waited > eta + eta / 5)) && pose=sweat
      case $answer in
      '') bubble="Serve $name+$code ($sha) to $onto? [Y/n] $((30 - waited))s" ;;
      n) bubble="Non? Fine. It goes on the shelf when it's done." ;;
      *) bubble=$(chef_quip "$tick") ;;
      esac
      [[ $pose == sweat ]] && ((tick / 24 % 2)) && bubble="This is taking longer than last time..."
      if [[ -n $built ]]; then
        pose=ask
        bubble="Order up! Serve to $onto? [Y/n] $((30 - waited))s"
      fi
      chef_draw "$pose" "$tick" "$bubble" "$(chef_oven "$waited" "$eta")" "$step"

      if [[ -z $answer ]] && chef_key key; then
        case $key in
        '' | [yY]) answer=y ;;
        [nN]) answer=n ;;
        esac
      elif [[ -n $answer || -z $CHEF_TTY ]]; then
        sleep 0.25
      fi
      tick=$((tick + 1))
    done
    if ((built != 0)); then
      chef_end fire "$tick" "MON DIEU! $sha is burnt."
      echo
      tail -n 20 "$log" >&2
      return 3
    fi
    apk=$(<"$path")
    if [[ $answer == n ]]; then
      chef_end shelf "$tick" "On the shelf: $(basename "$apk")"
      say "left on the shelf: $apk"
      return 0
    fi
  fi

  local line was now failed=0
  for line in "${pending[@]}"; do
    IFS=$'\t' read -r label serial have <<<"$line"
    was=$(updated_at "$(dumpsys "$serial")")
    if ! serve "$label" "$serial" "$apk"; then
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
    mkdir -p "$OUT/installed" && ln -f "$apk" "$OUT/installed/$label.apk"
    say "$label: $have -> $name+$code ($sha), $(grep -oE 'firstInstallTime=[^ ]+ [^ ]+' <<<"$pkg" | head -1)"
  done
  if ((failed)); then
    chef_end sad 0 "Sent back from the table. Merde."
  else
    chef_end bow 1 "Bon appetit! $name+$code is served."
  fi
  return $failed
}

on() {
  local label=$1 serial=$2
  shift 2
  phone run -t "$label" -- adb -s "$serial" "$@"
}

# Sends a zstd patch against the apk the handset already holds, which it rebuilds
# from its own base.apk. Any miss returns 1 and the caller sends the whole apk.
patch_install() {
  local label=$1 serial=$2 apk=$3 dir=/data/local/tmp/upgrade-deploy
  local zstd_android=${DEPLOY_ZSTD_ANDROID:-} base have old cand want patch
  [[ -x $zstd_android ]] && command -v zstd >/dev/null || return 1
  base=$(on "$label" "$serial" shell pm path "$PKG" | sed -n 's/^package:\(.*\/base\.apk\)\r*$/\1/p')
  [[ -n $base ]] || return 1
  have=$(on "$label" "$serial" shell sha256sum "$base" | cut -d' ' -f1)
  for cand in "$OUT/installed/$label.apk" "$OUT"/upgrade-*.apk; do
    [[ -f $cand && $(sha256sum "$cand" | cut -d' ' -f1) == "$have" ]] && old=$cand && break
  done
  [[ -n ${old:-} ]] || return 1

  patch="$OUT/patch-$label.zst"
  zstd -q -f -19 -T0 --long=27 --patch-from="$old" "$apk" -o "$patch" || return 1
  (($(stat -c %s "$patch") * 2 < $(stat -c %s "$apk"))) || return 1
  echo "deploy: $label: patch of $(du -h "$patch" | cut -f1) against $(basename "$old")"

  want=$(sha256sum "$zstd_android" | cut -d' ' -f1)
  if [[ $(on "$label" "$serial" shell sha256sum "$dir/zstd" 2>/dev/null | cut -d' ' -f1) != "$want" ]]; then
    on "$label" "$serial" shell mkdir -p "$dir" &&
      on "$label" "$serial" push "$zstd_android" "$dir/zstd" >/dev/null &&
      on "$label" "$serial" shell chmod 755 "$dir/zstd" || return 1
  fi
  on "$label" "$serial" push "$patch" "$dir/apk.zst" >/dev/null || return 1
  want=$(sha256sum "$apk" | cut -d' ' -f1)
  on "$label" "$serial" shell "
    $dir/zstd -q -f -d --long=27 --patch-from='$base' $dir/apk.zst -o $dir/new.apk &&
    [ \"\$(sha256sum $dir/new.apk | cut -d' ' -f1)\" = $want ] &&
    pm install -r $dir/new.apk
    rc=\$?; rm -f $dir/apk.zst $dir/new.apk; exit \$rc"
}

deliver() {
  patch_install "$@" && return
  echo "deploy: $1: sending the whole apk"
  phone app install -t "$1" "$3"
}

serve() {
  local label=$1 serial=$2 apk=$3 tick=0 out="$OUT/install.log"
  if ! ((CHEF_ON)); then
    deliver "$label" "$serial" "$apk"
    return
  fi
  deliver "$label" "$serial" "$apk" >"$out" 2>&1 &
  local installing=$!
  while kill -0 "$installing" 2>/dev/null; do
    chef_draw walk "$tick" "Plating for $label, coming through!"
    sleep 0.25
    tick=$((tick + 1))
  done
  wait "$installing" && return
  chef_clear
  tail -n 10 "$out" >&2
  return 1
}

settle() {
  local now n first=$2
  SETTLED=$1
  while :; do
    if ((CHEF_ON)); then
      for ((n = 40; n > 0; n--)); do
        CHEF_LEFT=$(printf '%2ds' $(((n + 3) / 4)))
        if [[ -n $first ]]; then
          chef_draw settle "$TICK" "Opening the kitchen. Mise en place..."
        else
          chef_draw settle "$TICK" "A commit! $(git -C "$ROOT" rev-parse --short "$SETTLED") landed; letting the burst settle..."
        fi
        sleep 0.25
        TICK=$((TICK + 1))
      done
    else
      sleep 10
    fi
    now=$(head_rev)
    [[ $now == "$SETTLED" ]] && break
    SETTLED=$now
  done
}

idle() {
  local head=$1 sha subject phase n
  if ! ((CHEF_ON)); then
    sleep 5
    return
  fi
  sha=$(git -C "$ROOT" rev-parse --short "$head")
  subject=$(git -C "$ROOT" log -1 --format=%s "$head")
  for n in 1 2 3 4 5 6 7 8; do
    phase=$((TICK / 40 % ${#CHEF_IDLE[@]}))
    local fill=$sha
    ((phase != 3)) || fill=$subject
    chef_draw "${CHEF_IDLE_POSES[$phase]}" "$TICK" "${CHEF_IDLE[$phase]/\%s/"$fill"}"
    sleep 0.25
    TICK=$((TICK + 1))
  done
}

watch() {
  local seen="" broken="" head rc
  TICK=0
  say "watching HEAD of $ROOT for ${*:-every handset attached}; ^C stops"
  chef_open
  trap 'chef_close; exit 130' INT TERM
  trap chef_close EXIT
  while :; do
    head=$(head_rev)
    if [[ $head == "$seen" || $head == "$broken" ]]; then
      idle "$head"
      continue
    fi
    settle "$head" "$([[ -z $seen && -z $broken ]] && echo first)"
    head=$SETTLED
    chef_clear
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
