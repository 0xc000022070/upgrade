default:
    @just --list

# Regenerate drift / build_runner output. Not committed; run after schema edits.
gen:
    flutter pub run build_runner build

gen-watch:
    flutter pub run build_runner watch

# Mirror the artist's production assets into assets/. Re-run when design/ moves.
assets:
    #!/usr/bin/env bash
    set -euo pipefail
    src=design/production
    rm -f assets/icons/*.svg assets/icons/signal/*.svg assets/textures/*
    mkdir -p assets/icons/signal assets/textures
    cp "$src"/icons/hl-*.svg assets/icons/
    cp "$src"/icons/signal/hl-*-signal.svg assets/icons/signal/
    cp "$src"/textures/noise-fine.png "$src"/textures/grid-8.svg "$src"/textures/scanline-3.png assets/textures/
    echo "assets: $(ls assets/icons/*.svg | wc -l) icons, $(ls assets/icons/signal/*.svg | wc -l) signal, $(ls assets/textures/* | wc -l) textures"

analyze: xterm-sync
    flutter analyze

fmt:
    dart format lib test

# `-j` is every core, not flutter's default of half of them: package:test
# parallelises by file, so the wall clock is the slowest file rather than the
# total, and half the cores left the tail of the run idle.

# The suite, or the paths named: `just test test/shell_tabs_test.dart`.
test *args: xterm-sync
    flutter test -j {{ num_cpus() }} {{ args }}

# Debug APK (arm64 only); the same artifact runs on the emulator and on faraday.
# DAZZLE_BUILD comes from the flake's shellHook and stamps §39.16's build line.
apk: xterm-sync
    flutter build apk --debug --target-platform android-arm64 --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

apk-fixtures: xterm-sync
    flutter build apk --debug --target-platform android-arm64 --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev} --dart-define=DAZZLE_SEED_FIXTURES=true

# Release APK, the artifact faraday is upgraded with. arm64 only: the emulator
# on rose and faraday are both arm64, and the other two ABIs were 40 of the
# 60 MB and two thirds of the AOT time. The build number is the one in pubspec;
# pass it explicitly because a bare release build has reported versionCode 1
# regardless of it.
apk-release version="1.0.0" code="1": xterm-verify
    flutter build apk --release --target-platform android-arm64 --build-name={{version}} --build-number={{code}} --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

# Emulator on rose: the only device this repo drives interactively.
dev:
    phone up --profile dev

# Hot reload against the emulator on rose, over a forwarded adb server socket.
# The inner loop: run once, then `kill -USR1 $(cat build/run.pid)` to reload and
# -USR2 to restart, instead of paying for an apk on every change.
run: xterm-sync
    #!/usr/bin/env bash
    set -euo pipefail
    ssh -fN -o ExitOnForwardFailure=yes -L 5038:127.0.0.1:5037 rose || true
    ADB_SERVER_SOCKET=tcp:127.0.0.1:5038 flutter run -d emulator-5554 \
        --pid-file build/run.pid \
        --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

# The certificate faraday's installed copy carries. Release signs with the debug
# keystore (android/app/build.gradle.kts), so this is ~/.android/debug.keystore
# on this machine; an apk from any other key can only land by uninstalling, and
# faraday holds real data.
faraday_cert := "d6b7cdfb8d0a5c0017e317b7db27f3fb3ce0b3f650f28ca6b989c4582f5d7e5e"

# Upgrade faraday to a release build of the current tree. Version and build
# number are read from pubspec.yaml, the one place they are declared, so the two
# apk-release arguments cannot drift from it. Installs in place and never
# launches: the user opens the app themselves.
faraday:
    #!/usr/bin/env bash
    set -euo pipefail

    stamp=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]\{1,\}\)+\([0-9]\{1,\}\)[[:space:]]*$/\1 \2/p' pubspec.yaml)
    [[ -n $stamp ]] || { echo "faraday: pubspec.yaml has no 'version: <name>+<code>' line" >&2; exit 1; }
    read -r version code <<<"$stamp"

    tools=${ANDROID_HOME:?run inside the nix dev shell}/build-tools/37.0.0

    # Reachability first: a dead transport should not cost an AOT build.
    attached() { phone device list | grep -qE '^android[[:space:]]+faraday[[:space:]].*(attached|online)'; }
    attached || phone device connect faraday
    attached || { echo "faraday: no transport after connect" >&2; exit 1; }
    # The table's last column is the pinned endpoint, not the live transport: a
    # USB session there still reads faraday:5555. The JSON row carries the serial.
    serial=$(phone device list --json | tr -d '\n' | grep -oE '"label": "faraday"[^}]*"serial": "[^"]+"' | sed 's/.*"serial": "//; s/"$//')
    [[ -n $serial ]] || { echo "faraday: no serial in phone device list --json" >&2; exit 1; }

    export DAZZLE_BUILD="${DAZZLE_BUILD:-$(git rev-parse --short HEAD)}"
    git diff --quiet HEAD || echo "faraday: tree is dirty, the build line still stamps $DAZZLE_BUILD" >&2

    # Removed first so a failed build cannot leave a previous apk to verify.
    apk=build/app/outputs/flutter-apk/app-release.apk
    rm -f "$apk"
    just apk-release "$version" "$code"

    badged=$("$tools/aapt2" dump badging "$apk" | sed -n "1s/.*versionCode='\([0-9]*\)'.*/\1/p")
    [[ $badged == "$code" ]] || { echo "faraday: apk reports versionCode $badged, pubspec says $code" >&2; exit 1; }
    cert=$("$tools/apksigner" verify --print-certs "$apk" | awk '/certificate SHA-256 digest:/ {print $NF; exit}')
    [[ $cert == "{{faraday_cert}}" ]] || { echo "faraday: apk signed by $cert, not the key faraday trusts" >&2; exit 1; }

    # dumpsys is the one confirmation `phone` has no verb for. The timestamp is
    # read first because a rebuild at an unchanged build number proves nothing
    # by versionCode alone.
    dumpsys() { adb -s "$serial" shell dumpsys package dev.luisnquin.dazzle; }
    was=$(dumpsys | sed -n 's/.*lastUpdateTime=//p' | head -1)

    phone app install -t faraday "$apk"

    pkg=$(dumpsys)
    installed=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' <<<"$pkg" | head -1)
    [[ $installed == "$code" ]] || { echo "faraday: still on versionCode $installed after install" >&2; exit 1; }
    now=$(sed -n 's/.*lastUpdateTime=//p' <<<"$pkg" | head -1)
    [[ -z $was || $now != "$was" ]] || { echo "faraday: lastUpdateTime still $was, nothing was replaced" >&2; exit 1; }
    grep -E 'firstInstallTime|lastUpdateTime' <<<"$pkg"
    echo "faraday: $version+$code ($DAZZLE_BUILD) installed on $serial"

# Where the apk faraday pulls is staged. Inside the tree and gitignored, and not
# under build/, which `flutter clean` empties.
apk_repo := justfile_directory() / "publish"

# Build and verify a release apk and leave it where faraday can fetch it over
# the tailnet, for the stretch with no adb transport to push over. The three
# assertions `faraday` makes matter more here, not less: nothing on the other
# end reads them back, the phone installs whatever this directory holds.
#
#     just publish
#     tailscale serve --bg publish   # https://<this host>.<tailnet>.ts.net
#
# One apk is kept, never a history. dumpsys cannot confirm the install from
# here either: §39.16's BUILD line in SYS is what says which one landed.
publish:
    #!/usr/bin/env bash
    set -euo pipefail

    stamp=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]\{1,\}\)+\([0-9]\{1,\}\)[[:space:]]*$/\1 \2/p' pubspec.yaml)
    [[ -n $stamp ]] || { echo "publish: pubspec.yaml has no 'version: <name>+<code>' line" >&2; exit 1; }
    read -r version code <<<"$stamp"

    tools=${ANDROID_HOME:?run inside the nix dev shell}/build-tools/37.0.0

    export DAZZLE_BUILD="${DAZZLE_BUILD:-$(git rev-parse --short HEAD)}"
    git diff --quiet HEAD || echo "publish: tree is dirty, the build line still stamps $DAZZLE_BUILD" >&2

    apk=build/app/outputs/flutter-apk/app-release.apk
    rm -f "$apk"
    just apk-release "$version" "$code"

    badged=$("$tools/aapt2" dump badging "$apk" | sed -n "1s/.*versionCode='\([0-9]*\)'.*/\1/p")
    [[ $badged == "$code" ]] || { echo "publish: apk reports versionCode $badged, pubspec says $code" >&2; exit 1; }
    cert=$("$tools/apksigner" verify --print-certs "$apk" | awk '/certificate SHA-256 digest:/ {print $NF; exit}')
    [[ $cert == "{{faraday_cert}}" ]] || { echo "publish: apk signed by $cert, not the key faraday trusts" >&2; exit 1; }

    # '-' and not '+' before the code: a literal + in a url path is legal and
    # reads as a space to enough clients to not be worth finding out which.
    name="dazzle-$version-$code.apk"
    mkdir -p "{{apk_repo}}"
    rm -f "{{apk_repo}}"/dazzle-*.apk "{{apk_repo}}/latest.apk"
    install -m644 "$apk" "{{apk_repo}}/$name"
    # A hard link, so the stable url costs no second copy of 60 MB and does not
    # depend on the file server following symlinks out of its own root.
    ln "{{apk_repo}}/$name" "{{apk_repo}}/latest.apk"

    sum=$(sha256sum "{{apk_repo}}/$name" | cut -d' ' -f1)
    size=$(du -h "{{apk_repo}}/$name" | cut -f1)
    when=$(date -Is)

    # The page is read on the phone that is about to install from it: one link
    # big enough to hit, and the stamp to compare against SYS afterwards.
    {
        printf '<!doctype html><meta charset=utf-8>'
        printf '<meta name=viewport content="width=device-width,initial-scale=1">'
        printf '<title>dazzle</title>'
        printf '<style>body{background:#111;color:#eee;font:14px/1.6 ui-monospace,monospace;margin:0;padding:2rem 1.25rem;max-width:34rem}'
        printf 'a.get{display:block;padding:1.1rem;margin:1.5rem 0;background:#eee;color:#111;text-align:center;text-decoration:none;letter-spacing:.08em}'
        printf 'dt{color:#777;float:left;width:5.5rem;clear:left}dd{margin:0 0 .35rem 5.5rem;word-break:break-all}</style>'
        printf '<h1>DAZZLE</h1>'
        printf '<a class="get" href="%s">INSTALL %s (%s)</a>' "$name" "$version" "$code"
        printf '<dl>'
        printf '<dt>build</dt><dd>%s</dd>' "$DAZZLE_BUILD"
        printf '<dt>size</dt><dd>%s</dd>' "$size"
        printf '<dt>built</dt><dd>%s</dd>' "$when"
        printf '<dt>sha256</dt><dd>%s</dd>' "$sum"
        printf '</dl>'
        printf '<p style="color:#777">SYS must read v%s (%s) %s once it lands.</p>' "$version" "$code" "$DAZZLE_BUILD"
    } > "{{apk_repo}}/index.html"

    echo "publish: $name ($DAZZLE_BUILD) -> {{apk_repo}}"

# faraday: install and launch only, for the user to review by hand.
review:
    phone up --profile review

desktop: xterm-sync
    flutter run -d linux --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

# Put our xterm changes into the resolved package. Run after a clone, after a
# `pub get` that refetched it, and after `dart pub cache repair`. Refuses to
# overwrite a package somebody is in the middle of editing.
xterm-sync:
    tool/xterm-patches.sh sync

# Rewrite packages/xterm/patches from the package in the cache.
xterm-patches:
    tool/xterm-patches.sh generate

# Prove the package in the cache is pristine upstream plus the series.
xterm-verify:
    tool/xterm-patches.sh verify

# Discard whatever is in the cache and write pristine upstream plus the series.
xterm-apply:
    tool/xterm-patches.sh apply

# Hand the cache back to upstream, for every other project on this machine.
xterm-reset:
    tool/xterm-patches.sh reset
