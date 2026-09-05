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

analyze:
    flutter analyze

fmt:
    dart format lib test

# Debug APK (arm64 only); the same artifact runs on the emulator and on faraday.
# SPECTACLE_BUILD comes from the flake's shellHook and stamps §39.16's build line.
apk:
    flutter build apk --debug --target-platform android-arm64 --dart-define=SPECTACLE_BUILD=${SPECTACLE_BUILD:-dev}

# Release APK, the artifact faraday is upgraded with. arm64 only: the emulator
# on rose and faraday are both arm64, and the other two ABIs were 40 of the
# 60 MB and two thirds of the AOT time. The build number is the one in pubspec;
# pass it explicitly because a bare release build has reported versionCode 1
# regardless of it.
apk-release version="1.0.0" code="1":
    flutter build apk --release --target-platform android-arm64 --build-name={{version}} --build-number={{code}} --dart-define=SPECTACLE_BUILD=${SPECTACLE_BUILD:-dev}

# Emulator on rose: the only device this repo drives interactively.
dev:
    phone up --profile dev

# Hot reload against the emulator on rose, over a forwarded adb server socket.
# The inner loop: run once, then `kill -USR1 $(cat build/run.pid)` to reload and
# -USR2 to restart, instead of paying for an apk on every change.
run:
    #!/usr/bin/env bash
    set -euo pipefail
    ssh -fN -o ExitOnForwardFailure=yes -L 5038:127.0.0.1:5037 rose || true
    ADB_SERVER_SOCKET=tcp:127.0.0.1:5038 flutter run -d emulator-5554 \
        --pid-file build/run.pid \
        --dart-define=SPECTACLE_BUILD=${SPECTACLE_BUILD:-dev}

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
    attached() { phone device list | grep -qE '^android[[:space:]]+faraday[[:space:]].*attached'; }
    attached || phone device connect faraday
    attached || { echo "faraday: no transport after connect" >&2; exit 1; }
    serial=$(phone device list | grep -E '^android[[:space:]]+faraday[[:space:]]' | grep -oE '[^[:space:]]+:[0-9]+' | head -1)

    export SPECTACLE_BUILD="${SPECTACLE_BUILD:-$(git rev-parse --short HEAD)}"
    git diff --quiet HEAD || echo "faraday: tree is dirty, the build line still stamps $SPECTACLE_BUILD" >&2

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
    dumpsys() { adb -s "$serial" shell dumpsys package dev.luisnquin.spectacle; }
    was=$(dumpsys | sed -n 's/.*lastUpdateTime=//p' | head -1)

    phone app install -t faraday "$apk"

    pkg=$(dumpsys)
    installed=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' <<<"$pkg" | head -1)
    [[ $installed == "$code" ]] || { echo "faraday: still on versionCode $installed after install" >&2; exit 1; }
    now=$(sed -n 's/.*lastUpdateTime=//p' <<<"$pkg" | head -1)
    [[ -z $was || $now != "$was" ]] || { echo "faraday: lastUpdateTime still $was, nothing was replaced" >&2; exit 1; }
    grep -E 'firstInstallTime|lastUpdateTime' <<<"$pkg"
    echo "faraday: $version+$code ($SPECTACLE_BUILD) installed on $serial"

# faraday: install and launch only, for the user to review by hand.
review:
    phone up --profile review

desktop:
    flutter run -d linux --dart-define=SPECTACLE_BUILD=${SPECTACLE_BUILD:-dev}
