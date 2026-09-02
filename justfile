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
# HOTLINE_BUILD comes from the flake's shellHook and stamps §39.16's build line.
apk:
    flutter build apk --debug --target-platform android-arm64 --dart-define=HOTLINE_BUILD=${HOTLINE_BUILD:-dev}

# Release APK, the artifact faraday is upgraded with. arm64 only: the emulator
# on rose and faraday are both arm64, and the other two ABIs were 40 of the
# 60 MB and two thirds of the AOT time. The build number is the one in pubspec;
# pass it explicitly because a bare release build has reported versionCode 1
# regardless of it.
apk-release version="1.0.0" code="1":
    flutter build apk --release --target-platform android-arm64 --build-name={{version}} --build-number={{code}} --dart-define=HOTLINE_BUILD=${HOTLINE_BUILD:-dev}

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
        --dart-define=HOTLINE_BUILD=${HOTLINE_BUILD:-dev}

# faraday: install and launch only, for the user to review by hand.
review:
    phone up --profile review

desktop:
    flutter run -d linux --dart-define=HOTLINE_BUILD=${HOTLINE_BUILD:-dev}
