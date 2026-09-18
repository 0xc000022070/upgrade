default:
    @just --list

# A guest half-booted answers the port and not the handshake.
host_vm_probe := "bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222 && head -c 3 <&3 | grep -q SSH' 2>/dev/null"

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

analyze: xterm-build
    flutter analyze

fmt:
    dart format lib test

# `-j` is every core, not flutter's default of half: package:test parallelises by
# file, so the wall clock is the slowest file and half the cores left the tail idle.

# The suite, or the paths named. The `host` tier stays out; see `just test-host`.
test *args: xterm-build
    flutter test -j {{ num_cpus() }} --exclude-tags host {{ args }}

# `-j 1` because every one of these dials the same guest, and scoped to test/host
# because `--tags` loads every file it is pointed at before it can see none is tagged.

# The tier that wants a machine on the other end of the socket.
test-host *args: xterm-build
    #!/usr/bin/env bash
    set -euo pipefail
    just host-vm
    flutter test -j 1 --tags host {{ if args == "" { "test/host" } else { args } }}

# Everything, both tiers, the fixture VM included. What a release is gated on.
test-all *args:
    #!/usr/bin/env bash
    set -euo pipefail
    just test {{ args }}
    just test-host

# The fixture VM, up and answering. Idempotent, so it is safe in front of any recipe.
host-vm:
    #!/usr/bin/env bash
    set -euo pipefail
    if {{ host_vm_probe }}; then echo "host vm: up"; exit 0; fi
    log="${TMPDIR:-/tmp}/dazzle-host-vm.log"
    echo "host vm: booting, log $log"
    # setsid: a guest that died with the recipe would be booted again per test file.
    nohup setsid --wait nix run .#host-vm -- -nographic </dev/null >"$log" 2>&1 &
    vm=$!
    for _ in $(seq 1 180); do
        if {{ host_vm_probe }}; then echo "host vm: up"; exit 0; fi
        # qemu gives up on a port it cannot forward in under a second, so a dead
        # guest is told from a slow one rather than waited out for six minutes.
        if ! kill -0 "$vm" 2>/dev/null; then
            echo "host vm: the guest exited while booting; see $log" >&2
            tail -n 3 "$log" >&2
            exit 1
        fi
        sleep 2
    done
    echo "host vm: no sshd on 2222 after six minutes; see $log" >&2
    exit 1

# Stop the fixture VM. The disk image is kept: a test pins the host key in it.
host-vm-down:
    #!/usr/bin/env bash
    set -euo pipefail
    # Matched on qemu's own `-name`: the nix runner execs into qemu.
    pkill -f 'qemu-system-.* -name dazzle-host' || true
    echo "host vm: down"

# Debug APK (arm64 only); the same artifact runs on the emulator and on faraday.
apk: xterm-build
    flutter build apk --debug --target-platform android-arm64 --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

apk-fixtures: xterm-build
    flutter build apk --debug --target-platform android-arm64 --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev} --dart-define=DAZZLE_SEED_FIXTURES=true

# The build number is passed explicitly because a bare release build has reported
# versionCode 1 regardless of what pubspec declares.

# Release APK, the artifact faraday is upgraded with. arm64 only.
apk-release version="1.0.0" code="1": xterm-verify
    flutter build apk --release --target-platform android-arm64 --build-name={{version}} --build-number={{code}} --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

# Emulator on rose: the only device this repo drives interactively.
dev:
    phone up --profile dev

# Hot reload on rose's emulator: `kill -USR1 $(cat build/run.pid)` reloads, -USR2 restarts.
run: xterm-build
    #!/usr/bin/env bash
    set -euo pipefail
    ssh -fN -o ExitOnForwardFailure=yes -L 5038:127.0.0.1:5037 rose || true
    ADB_SERVER_SOCKET=tcp:127.0.0.1:5038 flutter run -d emulator-5554 \
        --pid-file build/run.pid \
        --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

# ~/.android/debug.keystore on this machine, which release signs with. An apk from
# any other key can only land by uninstalling, and faraday holds real data.
faraday_cert := "d6b7cdfb8d0a5c0017e317b7db27f3fb3ce0b3f650f28ca6b989c4582f5d7e5e"

# Upgrade faraday to a release build of this tree. Installs in place, never launches.
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
    # The table's last column is the pinned endpoint, not the live transport: a USB
    # session still reads faraday:5555. Only the JSON row carries the serial.
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

    # Read first: a rebuild at an unchanged build number proves nothing by
    # versionCode alone, and dumpsys is the one confirmation `phone` has no verb for.
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

# Nothing on the other end reads the assertions back: the phone installs whatever
# this directory holds, and the BUILD line in SYS is what says which one landed.
#
#     just publish
#     tailscale serve --bg publish   # https://<this host>.<tailnet>.ts.net

# A release apk left where faraday can fetch it over the tailnet, with no adb transport.
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

    # '-' and not '+': a literal + in a url path reads as a space to enough clients.
    name="dazzle-$version-$code.apk"
    mkdir -p "{{apk_repo}}"
    rm -f "{{apk_repo}}"/dazzle-*.apk "{{apk_repo}}/latest.apk"
    install -m644 "$apk" "{{apk_repo}}/$name"
    # A hard link: no second copy of 60 MB, and no symlink out of the server's root.
    ln "{{apk_repo}}/$name" "{{apk_repo}}/latest.apk"

    sum=$(sha256sum "{{apk_repo}}/$name" | cut -d' ' -f1)
    size=$(du -h "{{apk_repo}}/$name" | cut -f1)
    when=$(date -Is)

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

desktop: xterm-build
    flutter run -d linux --dart-define=DAZZLE_BUILD=${DAZZLE_BUILD:-dev}

# Write upstream's xterm plus packages/xterm/patches into .dart_tool. A no-op when current.
xterm-build:
    tool/xterm-patches.sh build

# Rewrite packages/xterm/patches from edits made to .dart_tool/xterm.
xterm-patches:
    tool/xterm-patches.sh generate

# Prove the patches reproduce .dart_tool/xterm exactly.
xterm-verify:
    tool/xterm-patches.sh verify
