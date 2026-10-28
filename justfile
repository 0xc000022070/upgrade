default:
    @just --list

# Regenerate drift / build_runner output. Not committed; run after schema edits.
gen:
    flutter pub run build_runner build

gen-watch:
    flutter pub run build_runner watch

analyze: pub-build
    flutter analyze

fmt:
    dart format lib test

# tool/test.sh says what each tier holds.

# The suite under test/, or the paths named. `host` stays out.
test *args: pub-build
    tool/test.sh local {{ args }}

# Formatting, analysis and the local suite, which also fails a file or a run that
# goes over its time budget. TEST_FILE_BUDGET and TEST_WALL_BUDGET move the budgets.
check: pub-build
    dart format --output=none --set-exit-if-changed lib test tool
    flutter analyze
    tool/test.sh check

# The tests that pump no widget: the quick loop.
test-unit: pub-build
    tool/test.sh unit

# The tier that wants a machine on the other end of the socket.
test-host *args: pub-build
    tool/test.sh host {{ args }}

# Both tiers, the fixture VM included. What a release is gated on.
test-all: pub-build
    tool/test.sh all

# The fixture VM, up and answering. Idempotent, so it is safe in front of any recipe.
host-vm:
    nix run .#host-up

# Stop the fixture VM. The disk image is kept: a test pins the host key in it.
host-vm-down:
    #!/usr/bin/env bash
    set -euo pipefail
    # Matched on qemu's own `-name`: the nix runner execs into qemu.
    pkill -f 'qemu-system-.* -name striked-host( |$)' || true
    echo "host vm: down"

phone-host address scenario="full":
    tool/phone-host.sh {{address}} {{scenario}}

host-scenario name:
    nix run .#host-up-{{name}}

[positional-arguments]
plugin *args:
    @dart run tool/striked_plugin.dart "$@"

[positional-arguments]
plugin-sync dir scenario="":
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$1
    scenario=${2:-}
    app=".#host-ssh${scenario:+-$scenario}"
    name=$(basename "$(realpath "$dir")")
    case "$name" in /|.|..|'') echo "plugin-sync: $dir has no usable name" >&2; exit 2 ;; esac
    remote="Projects/plugins/$name"
    q=$(printf %q "$remote")
    tar -C "$dir" --exclude=.striked -cf - . | nix run "$app" -- \
        "set -e; rm -rf $q.sync $q.old; mkdir -p $q.sync/.striked; tar -C $q.sync -xf -; \
        if [ -d $q/.striked ]; then rm -rf $q.sync/.striked; mv $q/.striked $q.sync/; fi; \
        touch $q.sync/.striked/synced; if [ -e $q ]; then mv $q $q.old; fi; mv $q.sync $q"
    mkdir -p "$dir/.striked/preview"
    if nix run "$app" -- "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
        [ $q/.striked/preview/latest.json -nt $q/.striked/synced ] && break; sleep 0.5; done; \
        cat $q/.striked/preview/latest.json" > "$dir/.striked/preview/latest.json.part" 2>/dev/null; then
        mv "$dir/.striked/preview/latest.json.part" "$dir/.striked/preview/latest.json"
    else
        rm -f "$dir/.striked/preview/latest.json.part"
    fi
    echo "synced ~/$remote"

host-scenario-down name:
    pkill -f 'qemu-system-.* -name striked-host-{{name}}( |$)' || true

build_name := `sed -n 's/^version:[[:space:]]*\([^+[:space:]]\{1,\}\).*$/\1/p' pubspec.yaml`
build_code := `git rev-list --count HEAD 2>/dev/null || echo 1`
stamp := "--build-name=" + build_name + " --build-number=" + build_code + " --dart-define=STRIKED_BUILD=${STRIKED_BUILD:-dev}"

# Debug APK (arm64 only); the same artifact runs on the emulator and on faraday.
apk: pub-build
    flutter build apk --debug --target-platform android-arm64 {{stamp}}

apk-fixtures: pub-build
    flutter build apk --debug --target-platform android-arm64 {{stamp}} --dart-define=STRIKED_SEED_FIXTURES=true

# Release APK, the artifact faraday is upgraded with. arm64 only.
apk-release version=build_name code=build_code: pub-verify
    flutter build apk --release --target-platform android-arm64 --build-name={{version}} --build-number={{code}} --dart-define=STRIKED_BUILD=${STRIKED_BUILD:-dev}

# Emulator on rose: the only device this repo drives interactively.
dev:
    phone up --profile dev

# Hot reload on rose's emulator: `kill -USR1 $(cat build/run.pid)` reloads, -USR2 restarts.
run: pub-build
    #!/usr/bin/env bash
    set -euo pipefail
    ssh -fN -o ExitOnForwardFailure=yes -L 5038:127.0.0.1:5037 rose || true
    ADB_SERVER_SOCKET=tcp:127.0.0.1:5038 flutter run -d emulator-5554 \
        --pid-file build/run.pid \
        --dart-define=STRIKED_BUILD=${STRIKED_BUILD:-dev}

# The build number is the commit count at HEAD, so a handset already there is
# left alone. `just watch` repeats this at every commit, asking in the pane first.
# Upgrade the handsets to a release build of HEAD. Installs in place, never launches.
deploy *devices:
    tool/deploy.sh once {{devices}}

watch *devices:
    tool/deploy.sh watch {{devices}}

faraday: (deploy "faraday")

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

    rev=$(git rev-parse HEAD)
    read -r version code STRIKED_BUILD <<<"$(tool/deploy.sh stamp "$rev")"
    apk=$(tool/deploy.sh build "$rev")

    # '-' and not '+': a literal + in a url path reads as a space to enough clients.
    name="striked-$version-$code.apk"
    mkdir -p "{{apk_repo}}"
    rm -f "{{apk_repo}}"/striked-*.apk "{{apk_repo}}/latest.apk"
    install -m644 "$apk" "{{apk_repo}}/$name"
    # A hard link: no second copy of 60 MB, and no symlink out of the server's root.
    ln "{{apk_repo}}/$name" "{{apk_repo}}/latest.apk"

    sum=$(sha256sum "{{apk_repo}}/$name" | cut -d' ' -f1)
    size=$(du -h "{{apk_repo}}/$name" | cut -f1)
    when=$(date -Is)

    {
        printf '<!doctype html><meta charset=utf-8>'
        printf '<meta name=viewport content="width=device-width,initial-scale=1">'
        printf '<title>striked</title>'
        printf '<style>body{background:#111;color:#eee;font:14px/1.6 ui-monospace,monospace;margin:0;padding:2rem 1.25rem;max-width:34rem}'
        printf 'a.get{display:block;padding:1.1rem;margin:1.5rem 0;background:#eee;color:#111;text-align:center;text-decoration:none;letter-spacing:.08em}'
        printf 'dt{color:#777;float:left;width:5.5rem;clear:left}dd{margin:0 0 .35rem 5.5rem;word-break:break-all}</style>'
        printf '<h1>STRIKED</h1>'
        printf '<a class="get" href="%s">INSTALL %s (%s)</a>' "$name" "$version" "$code"
        printf '<dl>'
        printf '<dt>build</dt><dd>%s</dd>' "$STRIKED_BUILD"
        printf '<dt>size</dt><dd>%s</dd>' "$size"
        printf '<dt>built</dt><dd>%s</dd>' "$when"
        printf '<dt>sha256</dt><dd>%s</dd>' "$sum"
        printf '</dl>'
        printf '<p style="color:#777">SYS must read v%s (%s) %s once it lands.</p>' "$version" "$code" "$STRIKED_BUILD"
    } > "{{apk_repo}}/index.html"

    echo "publish: $name ($STRIKED_BUILD) -> {{apk_repo}}"

# faraday: install and launch only, for the user to review by hand.
review:
    phone up -t faraday

desktop: pub-build
    flutter run -d linux --dart-define=STRIKED_BUILD=${STRIKED_BUILD:-dev}

widgetbook port="8095": pub-build
    cd widgetbook && flutter run -d web-server --web-hostname 127.0.0.1 --web-port {{port}}

widgetbook-build: pub-build
    cd widgetbook && flutter build web --no-wasm-dry-run

pub-build: mosh-build ssh-build flterm-build libghostty-build

pub-verify: mosh-verify ssh-verify flterm-verify

mosh-build:
    tool/pub-patches.sh dart_mosh build

mosh-patches:
    tool/pub-patches.sh dart_mosh generate

mosh-verify:
    tool/pub-patches.sh dart_mosh verify

ssh-build:
    tool/pub-patches.sh dartssh2 build

ssh-patches:
    tool/pub-patches.sh dartssh2 generate

ssh-verify:
    tool/pub-patches.sh dartssh2 verify

flterm-build:
    tool/pub-patches.sh flterm build

flterm-patches:
    tool/pub-patches.sh flterm generate

flterm-verify:
    tool/pub-patches.sh flterm verify

libghostty-build:
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

# The host engine. Its own toolchain and its own tree: nothing under engine/ is
# Dart, so `just analyze` and `just test` do not reach it and these do.
engine-build:
    cargo build --manifest-path engine/Cargo.toml --release

# The suite drives the built binary over stdin, so it is the protocol under test
# and not the functions behind it.
engine-test:
    cargo test --manifest-path engine/Cargo.toml

engine-gate:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo fmt --manifest-path engine/Cargo.toml --check
    cargo clippy --manifest-path engine/Cargo.toml --all-targets -- -D warnings
    cargo test --manifest-path engine/Cargo.toml

# One call answered end to end. Through `cargo run` and not a path under engine/,
# because CARGO_TARGET_DIR may put the binary anywhere.
engine-probe:
    echo '{"service":"lifecycle","op":"probe"}' | cargo run --quiet --release --manifest-path engine/Cargo.toml

# Re-pin the linux catalog's installer digests; `--check` writes nothing and fails on a move.
linux-catalog *args:
    dart tool/linux_catalog.dart {{args}}
