# Dazzle

Local-first personal control plane. Single user, no backend, no sync.
Design and art direction live in `design/SPEC.md`.

## Toolchain

Everything comes from the flake — nothing is expected on the host PATH.

```sh
direnv allow      # or: nix develop
```

The shell provides Flutter, Dart, SQLite, a JDK and an Android SDK, and rewrites
`android/local.properties` to match the current store paths. `adb` is left to the
host so it keeps ownership of the adb server.

## Common tasks

```sh
just gen          # build_runner: drift output (*.g.dart, *.drift.dart) — not committed
just analyze
just apk          # debug APK, arm64
just desktop      # Linux desktop, the fast iteration loop
```

Run `just gen` after touching a drift schema; generated Dart is gitignored.

## Device loop

`phone.toml` declares both development and review devices. For a single-device
review, build with `just apk`, then explicitly target the install and launch:

```sh
phone -t <device-id> app install build/app/outputs/flutter-apk/app-debug.apk
phone -t <device-id> app launch dev.luisnquin.dazzle
phone -t <device-id> shot --settle
```

`phone up` converges the project's declared devices, not just the handset being
reviewed. Use explicit installs when another device must remain undisturbed.

## Mobile plugins

The Plugins button beside Settings opens plugin management. Drops and Projects
are bundled native plugins; Agent schedules is a bundled Luau page. Home, Hosts,
SSH and Tools remain available without plugins. Tools lists enabled plugin pages,
including pages not pinned to navigation.

Native widgets declare compatible Home card or input-bar locations and size
constraints. Users can hide and reorder cards, choose a supported width, select
the input bar and pin a page. A fixed-size widget keeps its dimensions; an
incompatible placement reports why it cannot fit. Layout preferences survive
restart and disabling a plugin. This is a bounded layout prototype, not a
freeform canvas or support for embedding arbitrary Luau pages as widgets.

A bundled native module registers its builder under the declared `surface`:

```toml
[[contributes.widgets]]
id = "status"
title = "Host status"
surface = "example.status"
locations = ["home.card"]
default_location = "home.card"
default_size = "adaptive"
sizes = [
  { id = "compact", title = "Compact", width = 280, height = 160 },
  { id = "adaptive", title = "Adaptive", min_width = 280, max_width = 720 },
]
```

Dimensions use Flutter logical pixels. Exact `width` and a `min_width` / `max_width`
range are alternatives; omitted `height` lets content determine its height.
The input bar uses the exclusive `home.composer` location. Widget and page IDs
remain stable across renames because saved layouts refer to plugin ID plus
contribution ID, not the displayed title.

The source examples under `test/fixtures/plugins/record-text` and
`test/fixtures/plugins/record-restore` demonstrate selected-record actions and
shared read-only datasets. Record text proposes TRIM WHITESPACE or stores SAVE
SNAPSHOT. Record restore reads the exported snapshot and proposes RESTORE
SNAPSHOT. Only APPLY changes the selected built-in record; it rejects stale
proposals. Existing tables and attachments are not migrated.

Installed plugins expose ENABLE, DISABLE and REFRESH USAGE controls. Downloaded
plugins can also be removed; bundled native plugins stay installed.
Disable frees its cached VMs and invalidates queued work and old proposals.
Disable and removal retain datasets, usage and immutable source revisions.
Already committed private writes are not rolled back when a script fails or is
disabled. Disable dependents first before disabling their required provider.

ADD accepts a public GitHub repository and a ref: a branch, a tag or a full
commit SHA. Put `dazzle.plugin.toml` at the repository root; `plugins/example`
in this repository is a complete template a third party can copy, covering a
multi-file package and the listing fields. Review shows the resolved source
revision, declared capabilities and dependencies before granting installation.
Updates require another review, with added or retargeted capabilities marked
NEW. Unsupported retained revisions stay disabled with their original source
and grants, instead of resetting the catalog.

A plugin can span several files: `files` in the manifest lists paths beside
`dazzle.plugin.toml`, and Luau code loads them with
`require("path/without/extension")`. `require` only resolves files declared
in `files`; nothing else on the source repository is fetched. `author`,
`homepage`, `license` and `summary` are optional listing fields shown before
install and in the plugin detail sheet; they carry no capability or trust
meaning.

An index is a `dazzle.index.toml` at the repository root of a GitHub
repository at a ref, listing plugins with `[[plugins]]` entries:

```toml
index_version = 1

[[plugins]]
id = "dazzle.example"
repository = "https://github.com/x/example"
ref = "v2.0.0"
summary = "Minimal template a third-party author can copy"
author = "Dazzle"
```

Settings PLUGINS has SOURCES, where an index is added or removed by repository
and ref; no default source ships. BROWSE lists entries across added sources;
tapping one opens the same review flow with the entry's repository and ref
pre-filled. An entry already installed says so and offers UPDATE instead of
ADD. Index fetches are bounded and validated the same way plugin manifests
are; an index with unknown fields is rejected.

A dev-only override lets an author serve a plugin or index from a local
directory over HTTP while developing it, instead of GitHub:

```sh
flutter run --dart-define=DAZZLE_PLUGIN_ORIGIN=http://host:port
```

The override replaces the fetch base for both plugin and index requests and
only takes effect in debug builds; a release build ignores it. Serve the
override origin with the same layout GitHub raw content uses,
`<origin>/<owner>/<repo>/<ref>/<path>`, so ADD and BROWSE resolve `ref`
literally against whatever the local server has at that path, with no GitHub
ref lookup.

Version fields have different jobs: `manifest_version` versions the TOML schema,
`version` versions the plugin, and `dazzle_api` constrains the host API.
`[dependencies]` maps plugin IDs to semantic-version constraints. Dependencies
must be installed, enabled and compatible; cycles and changes that break enabled
dependents are rejected. A dependency grants no extra permissions and does not
share a VM. Dataset schema versions, capability API versions and exported
contracts are separate fields. Bundled native features use host-owned services
and surface builders; downloaded plugins use the Luau runtime.

Manifest format 2 uses named data bindings: `selection`, `self:name`, or
`plugin.id:name`. Data access uses `dazzle.data.get/query/put/delete/propose`.
Foreign reads require a declared dependency, matching export contract and an
explicit grant; foreign writes are unavailable. Dependencies alone grant no
data access. Every dataset has a separate host-owned SQLite database, scoped
to plugin ID, source identity and dataset name. Plugins get no SQL or file paths.
Writes require the expected record revision, and quota failures leave existing
records intact. Schema mismatches stop access without resetting storage.

The plugin detail sheet reports logical bytes, records, physical database and
journal bytes, API calls and rejections, transferred bytes, writes, deletes,
proposals, host API time and current VM allocation. Last-run timings are
in-memory; dataset counters persist. Shared runtime/registry overhead is not
charged to an individual dataset. Script time is wall time excluding host
callbacks, not a CPU-time or battery measurement.

The embedded interpreter is Luau 0.738, pinned by revision and archive digest in
`packages/dazzle_luau/hook/build.dart`. First native build downloads its source;
the phone downloads only plugin source, never native code or bytecode. Luau's
license is included in the package and Flutter's license bundle. No JIT is built.

Actions run on a lazy worker isolate, with at most two resident VMs and eight
pending calls. Each VM has an 8 MiB allocator budget; execution checks a 50 ms
deadline and a 100,000-safe-point ceiling. These are cooperative VM limits, not
an OS security boundary or hard real-time guarantees. Compilation runs off the
UI isolate with a 64 KiB source limit; compiler allocations are outside the VM
heap budget. The worker releases VMs on backgrounding or after 30 seconds idle.
Data calls are capped at 64 per invocation, with 16 KiB values, 64 KiB pages,
256 KiB transferred payload and a 500 ms host-session budget starting at the
first API call and checked between operations. Each plugin reserves at most
32 MiB across eight datasets; each dataset permits at most 8 MiB and 10,000
records. Logical quotas do not include
SQLite journal/index overhead. Plugins have no arbitrary filesystem, socket,
shell or WASM API. Declared host capabilities can list hosts and invoke the
host-owned scheduler over SSH, with plugin/host permission checks. Agent
schedules uses this API; remote jobs are distinct from an on-phone background
Luau runtime. Disabling a scheduler plugin requests that its remote schedules
pause; re-enabling does not automatically resume them.

Run `dart run tool/plugin_benchmark.dart` for selected-record roundtrips, or
`dart run tool/plugin_dataset_benchmark.dart` for durable read/write/query
roundtrips and VM memory measurements on the host. Host numbers are not handset
performance evidence.
The same entry point runs under Android AOT with
`flutter build apk --profile --target-platform android-arm64 --target tool/plugin_benchmark.dart`.
That APK runs the benchmark instead of the app UI and prints its JSON to logcat.

## Second phone

The BUNDLE panel on SYS moves the hosts and keys to another phone without a
backend. EXPORT asks for a passphrase twice, seals every key with its private
half, every host with its pinned host key and VNC password, and every path into
one file, and hands the file to the system document picker as
`dazzle-<date>.bundle`. IMPORT picks a file, asks for the passphrase, shows
the count, and merges by id: nothing on the phone is deleted, and a bundle
naming a key neither side has is refused whole. The file is Argon2id plus an
XSalsa20-Poly1305 box, so it is safe to park in a drive or a chat with yourself;
the passphrase is not.

## Host setup

Dazzle uses one ordinary SSH key for shells, remote commands, and the VNC
tunnel. Copy the public key shown by the app into `~/.ssh/authorized_keys`
without a forced `command=`, `restrict`, or `permitopen` prefix. The key has the
same access as an interactive login for that account.

Install `mosh-server` for roaming shells. Dazzle uses SSH to authenticate and
start Mosh, then moves terminal traffic to Mosh's UDP range. A live Mosh tab
rehomes after the phone changes networks. If the server is absent or UDP cannot
connect, the same tab falls back to SSH. Open UDP ports `60000:61000` on hosts
whose firewall does not already allow Mosh.

Mosh does not depend on a multiplexer. Dazzle never inserts `tmux` around an
ordinary shell: every new or restored tab enters through the host's normal
login path, including any gateway or chooser configured there. Mosh keeps a
live tab roaming between networks; an app process restart opens a fresh shell.
Closing a tab kills only the Mosh server that tab owns.

The AGENTS panel and SEND need `herdr` on the non-interactive SSH `PATH`. Every
running herdr session is listed. An attached agent tab records the exact Herdr
session and pane, then attaches that pane again after a network change or app
restart. Herdr owns that process identity; Dazzle does not put tmux around it.
The pane still uses Mosh transport when the host has `mosh-server`, with SSH as
fallback. SEND starts its agent in herdr's default session, or in the one
session running when the default is not. Dazzle scans `~/Projects`,
`~/.dotfiles`, and `~/src` for Git checkouts. Clipboard attachments need
`wl-copy` and `wl-paste` on Wayland, `xclip` on X11, or `osascript` on macOS.

A passphrase prompt for the SSH key held by gpg-agent is asked for in the app
when the host runs `pinentry-gate` as its pinentry: each shell marks its pty
under `$XDG_RUNTIME_DIR/pinentry-gate/tty` with the pid of the ssh session or
Mosh server holding it, and the pinentry writes the request into every marked
terminal and rings its bell, while also asking on the computer. A Mosh tab
never sees the request itself, only the bell, and asks the host what is open.
The first answer wins.

An SSH login on Linux does not inherit the desktop display. Put this in the
login shell setup when agents started from Dazzle must read image attachments:

```sh
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  for socket in "$XDG_RUNTIME_DIR"/wayland-*; do
    [ -S "$socket" ] || continue
    WAYLAND_DISPLAY=${socket##*/}
    export WAYLAND_DISPLAY
    break
  done
fi
```

SCREEN forwards SSH to `127.0.0.1:5900`. A VNC server that offers RFB security
type `None`, such as `wayvnc`, needs nothing more; authentication stays at SSH.
A server that offers only VNC Authentication takes the password from the host's
`VNC PASSWORD` field. Apple Screen Sharing is one: turn on "VNC viewers may
control screen with password" under Screen Sharing's settings and put that
password in the field. Apple's own authentication types are not supported.
