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
apk:
    flutter build apk --debug --target-platform android-arm64

# Emulator on rose: the only device this repo drives interactively.
dev:
    phone up --profile dev

# faraday: install and launch only, for the user to review by hand.
review:
    phone up --profile review

desktop:
    flutter run -d linux
