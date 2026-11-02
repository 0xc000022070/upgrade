[private]
default:
    @just --list --unsorted

build_name := `sed -n 's/^version:[[:space:]]*\([^+[:space:]]\{1,\}\).*$/\1/p' pubspec.yaml`
build_code := `git rev-list --count HEAD 2>/dev/null || echo 1`

[group('dev')]
analyze: pub-build
    flutter analyze

# tool/test.sh says what each tier holds.
[group('dev')]
test *args: pub-build
    tool/test.sh local {{ args }}

# Also fails a file or a run over its time budget (TEST_FILE_BUDGET, TEST_WALL_BUDGET).
[group('dev')]
check: pub-build
    dart format --output=none --set-exit-if-changed lib test tool
    flutter analyze
    tool/test.sh check

[group('dev')]
apk: pub-build
    flutter build apk --debug --target-platform android-arm64 --build-name={{build_name}} --build-number={{build_code}} --dart-define=UPGRADE_BUILD=${UPGRADE_BUILD:-dev}

# Hot reload on rose's emulator: `kill -USR1 $(cat build/run.pid)` reloads, -USR2 restarts.
[group('dev')]
run: pub-build
    #!/usr/bin/env bash
    set -euo pipefail
    ssh -fN -o ExitOnForwardFailure=yes -L 5038:127.0.0.1:5037 rose || true
    ADB_SERVER_SOCKET=tcp:127.0.0.1:5038 flutter run -d emulator-5554 \
        --pid-file build/run.pid \
        --dart-define=UPGRADE_BUILD=${UPGRADE_BUILD:-dev}

# Release build of HEAD onto the handsets; `watch` repeats it at every commit.
[group('dev')]
deploy *devices:
    tool/deploy.sh once {{devices}}

[group('dev')]
watch *devices:
    tool/deploy.sh watch {{devices}}

[group('dev')]
host-vm scenario="full":
    nix run .#host-up{{ if scenario == "full" { "" } else { "-" + scenario } }}

# The disk image is kept: a test pins the host key in it.
[group('dev')]
host-vm-down scenario="full":
    pkill -f 'qemu-system-.* -name upgrade-host{{ if scenario == "full" { "" } else { "-" + scenario } }}( |$)' || true

[group('dev')]
phone-host address scenario="full":
    tool/phone-host.sh {{address}} {{scenario}}

[group('dev')]
[positional-arguments]
plugin *args:
    @dart run tool/upgrade_plugin.dart "$@"

[group('dev')]
plugin-sync dir scenario="":
    tool/plugin-sync.sh {{quote(dir)}} {{scenario}}

[group('dev')]
widgetbook port="8095": pub-build
    cd widgetbook && flutter run -d web-server --web-hostname 127.0.0.1 --web-port {{port}}

[group('dev')]
widgetbook-serve port="8096": widgetbook-build
    python3 -m http.server {{port}} --bind 127.0.0.1 --directory widgetbook/build/web

[group('dev')]
engine-gate:
    cargo fmt --manifest-path engine/Cargo.toml --check
    cargo clippy --manifest-path engine/Cargo.toml --all-targets -- -D warnings
    cargo test --manifest-path engine/Cargo.toml

[group('dev')]
pub-build: (pub "dart_mosh") (pub "dartssh2") (pub "flterm") _libghostty

[group('agents')]
gen:
    flutter pub run build_runner build

[group('agents')]
fmt:
    dart format lib test

[group('agents')]
test-host *args: pub-build
    tool/test.sh host {{ args }}

[group('agents')]
test-all: pub-build
    tool/test.sh all

[group('agents')]
apk-release version=build_name code=build_code: pub-verify
    flutter build apk --release --target-platform android-arm64 --build-name={{version}} --build-number={{code}} --obfuscate --split-debug-info=build/symbols/{{code}} --dart-define=UPGRADE_BUILD=${UPGRADE_BUILD:-dev}

[group('agents')]
publish:
    tool/publish.sh

[group('agents')]
widgetbook-build: pub-build
    cd widgetbook && flutter build web --no-wasm-dry-run

[group('agents')]
widgetbook-frames:
    flutter test tool/plugin_frames_test.dart

[group('agents')]
linux-catalog *args:
    dart tool/linux_catalog.dart {{args}}

# dart_mosh, dartssh2 or flterm, patched into .dart_tool: build (default), verify, generate, without.
[group('agents')]
pub package *cmd:
    tool/pub-patches.sh {{package}} {{ if cmd == "" { "build" } else { cmd } }}

[group('agents')]
pub-verify: (pub "dart_mosh" "verify") (pub "dartssh2" "verify") (pub "flterm" "verify")

_libghostty:
    #!/usr/bin/env bash
    set -euo pipefail
    out=.dart_tool/libghostty
    [[ $(cat "$out/.stamp" 2>/dev/null) == "${LIBGHOSTTY_REV:?run inside the nix dev shell}" ]] && exit 0
    rm -rf "$out.tmp"
    cp -r "$LIBGHOSTTY_SRC/packages/libghostty" "$out.tmp"
    chmod -R u+w "$out.tmp"
    echo "$LIBGHOSTTY_REV" >"$out.tmp/.stamp"
    rm -rf "$out"
    mv "$out.tmp" "$out"
    # The hook keeps any libghostty.so already in its output directory, which is
    # keyed by target and not by ghostty.version, so a new pin would load the old lib.
    rm -rf .dart_tool/hooks_runner/shared/libghostty
