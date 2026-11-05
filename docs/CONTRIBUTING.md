# Contributing to Upgrade

Building the app, the device loop and plugin runtime internals. User-facing
material is in the [README](../README.md); product rulings are in
[SPEC.md](SPEC.md). The development host VM and its scenarios are described in
[AGENTS.md](../AGENTS.md).

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
just pub-build    # flterm, dart_mosh, dartssh2 and pointycastle, patched, into .dart_tool
just analyze
just apk          # debug APK, arm64
```

Run `just gen` after touching a drift schema; generated Dart is gitignored.

Nothing in pub applies the patches under `packages/<name>/patches`, so
`dependency_overrides` points at the trees `just pub-build` writes into
`.dart_tool`: run it before the first `flutter pub get` in a fresh checkout.
`tool/pub-patches.sh --help` covers editing a series.

`just apk-release` builds an obfuscated arm64 release APK, with split debug
symbols under `build/symbols/<code>`.

## Device loop

`phone.toml` declares both development and review devices. For a single-device
review, build with `just apk`, then explicitly target the install and launch:

```sh
phone -t <device-id> app install build/app/outputs/flutter-apk/app-debug.apk
phone -t <device-id> app launch dev.luisnquin.upgrade
phone -t <device-id> shot --settle
```

`phone up` converges the project's declared devices, not just the handset being
reviewed. Use explicit installs when another device must remain undisturbed.

## Plugin authoring tools

`just plugin` is `dart run tool/upgrade_plugin.dart`, with `init`, `docs`,
`check` and `preview`. `just plugin-sync <dir> [scenario]` copies a workspace to
`~/Projects/plugins/<name>` on a fixture VM guest and copies the phone's
preview envelope back. The author-facing walkthrough is
[TOOL-TUTORIAL.md](TOOL-TUTORIAL.md); the template is
[plugins/templates/phone-card](../plugins/templates/phone-card/README.md); the
SDK is [packages/upgrade_luau](../packages/upgrade_luau/README.md).

## Plugin runtime internals

TOOLS > MANAGE PLUGINS opens plugin management. Drops, Projects, Agents, Chat
and Prompt are bundled native plugins; Agent tasks (`plugins/agent-schedules`,
id `upgrade.agent-schedules`), Board and Kanban are bundled Luau plugins. Home,
Machines and Tools remain available without plugins. Tools lists enabled plugin
pages, including pages not pinned to navigation.

### Widgets and layout

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

### Record actions

The source examples under `test/fixtures/plugins/record-text` and
`test/fixtures/plugins/record-restore` demonstrate selected-record actions and
shared read-only datasets. Record text proposes TRIM WHITESPACE or stores SAVE
SNAPSHOT. Record restore reads the exported snapshot and proposes RESTORE
SNAPSHOT. Only APPLY changes the selected built-in record; it rejects stale
proposals. Existing tables and attachments are not migrated.

### Lifecycle

Installed plugins expose ENABLE, DISABLE and REFRESH USAGE controls. Downloaded
plugins can also be removed; bundled native plugins stay installed.
Disable frees its cached VMs and invalidates queued work and old proposals.
Disable and removal retain datasets, usage and immutable source revisions.
Already committed private writes are not rolled back when a script fails or is
disabled. Disable dependents first before disabling their required provider.

### Sources, packages and indexes

ADD accepts a public GitHub repository and a ref: a branch, a tag or a full
commit SHA. Put `upgrade.plugin.toml` at the repository root; `plugins/example`
in this repository is a complete template a third party can copy, covering a
multi-file package and the listing fields. Review shows the resolved source
revision, declared capabilities and dependencies before granting installation.
Updates require another review, with added or retargeted capabilities marked
NEW. Unsupported retained revisions stay disabled with their original source
and grants, instead of resetting the catalog.

A plugin can span several files: `files` in the manifest lists paths beside
`upgrade.plugin.toml`, and Luau code loads them with
`require("path/without/extension")`. `require` only resolves files declared
in `files`; nothing else on the source repository is fetched. `author`,
`homepage`, `license` and `summary` are optional listing fields shown before
install and in the plugin detail sheet; they carry no capability or trust
meaning.

An index is a `upgrade.index.toml` at the repository root of a GitHub
repository at a ref, listing plugins with `[[plugins]]` entries:

```toml
index_version = 1

[[plugins]]
id = "upgrade.example"
repository = "https://github.com/x/example"
ref = "v2.0.0"
summary = "Minimal template a third-party author can copy"
author = "Upgrade"
```

TOOLS > MANAGE PLUGINS > BROWSE has `[ SOURCES ]`, where an index is added or
removed by repository and ref; no default source ships. Its `[ BROWSE ]` panel
lists entries across added sources; tapping one opens the same review flow with
the entry's repository and ref pre-filled. An entry already installed says so
and offers UPDATE instead of ADD. Index fetches are bounded and validated the
same way plugin manifests are; an index with unknown fields is rejected.

A dev-only override lets an author serve a plugin or index from a local
directory over HTTP while developing it, instead of GitHub:

```sh
flutter run --dart-define=UPGRADE_PLUGIN_ORIGIN=http://host:port
```

The override replaces the fetch base for both plugin and index requests and
only takes effect in debug builds; a release build ignores it. Serve the
override origin with the same layout GitHub raw content uses,
`<origin>/<owner>/<repo>/<ref>/<path>`, so ADD and BROWSE resolve `ref`
literally against whatever the local server has at that path, with no GitHub
ref lookup.

### Versions and dependencies

Version fields have different jobs: `manifest_version` versions the TOML schema,
`version` versions the plugin, and `upgrade_api` constrains the host API.
`[dependencies]` maps plugin IDs to semantic-version constraints. Dependencies
must be installed, enabled and compatible; cycles and changes that break enabled
dependents are rejected. A dependency grants no extra permissions and does not
share a VM. Dataset schema versions, capability API versions and exported
contracts are separate fields. Bundled native features use host-owned services
and surface builders; downloaded plugins use the Luau runtime.

### Data bindings and usage

Manifest format 2 uses named data bindings: `selection`, `self:name`, or
`plugin.id:name`. Data access uses `upgrade.data.get/query/put/delete/propose`.
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

### Interpreter and limits

The embedded interpreter is Luau 0.738, pinned by revision and archive digest in
`packages/upgrade_luau/hook/build.dart`. First native build downloads its source;
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
records. Logical quotas do not include SQLite journal/index overhead.

Plugins have no arbitrary filesystem, socket, shell or WASM API. Declared host
capabilities (`hosts`, `scheduler`, `run`, `agents`) reach registered hosts over
SSH with plugin and host permission checks; the
[SDK README](../packages/upgrade_luau/README.md) lists their operations. Agent
tasks uses the scheduler service; remote jobs are distinct from an on-phone
background Luau runtime. Disabling a scheduler plugin requests that its remote
schedules pause; re-enabling does not automatically resume them.

### Benchmarks

Run `dart run tool/plugin_benchmark.dart` for selected-record roundtrips, or
`dart run tool/plugin_dataset_benchmark.dart` for durable read/write/query
roundtrips and VM memory measurements on the host. Host numbers are not handset
performance evidence.
The same entry point runs under Android AOT with
`flutter build apk --profile --target-platform android-arm64 --target tool/plugin_benchmark.dart`.
That APK runs the benchmark instead of the app UI and prints its JSON to logcat.
