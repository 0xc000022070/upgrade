# Toolchain and machines

Everything runs through the flake: `nix develop -c <cmd>` or `just`.

| name | address | role |
|---|---|---|
| nyx | 100.118.60.77 | this machine; runs herdr; the app's first host once the user installs a key |
| rose | 100.73.224.47 | Apple silicon Mac; hosts `emulator-5554` (`pixel_7-api36`, arm64); parks release apks in `/tmp` |
| faraday | 100.127.25.101, adb `faraday:5555` | the user's phone; review only |

- `just gen` codegen, `just analyze`, `just fmt`, `just test`.
- `just apk` debug arm64. `just apk-release <version> <code>` release arm64; pass the build number from `pubspec.yaml`, a bare release build reports versionCode 1. Release arm64 builds take about half a minute; gradle speed comes from `~/.gradle/gradle.properties` (daemon on, 14g heap, 1g metaspace).
- `just run` hot reload against the emulator on rose, forwarding rose's adb server to `127.0.0.1:5038` over ssh. `kill -USR1 $(cat build/run.pid)` reloads, `-USR2` restarts. This is the inner loop; apks are for shipping.
- `phone` CLI for screenshots, taps, waits and recordings on the emulator. `phone shot --settle` after an action, never a sleep. `phone --help` and `phone help <verb>` carry the rest.
- Fold is simulated with `adb shell wm size 2232x2310`, reset with `wm size reset` when done.
- The emulator also hosts another app. A stray back key can foreground it; relaunch Dazzle with `am start`, touch nothing else.
- The emulator reaches nyx through the NAT. `100.64.0.253` is an unassigned CGNAT address, the unreachable probe.
- Keys for the app's hosts are installed by the user by hand.
- Herdr answers on the unix socket `~/.config/herdr/sessions/hub/herdr.sock`; `herdr agent list` is the shape the app parses: `id` `cli:agent:list`, `result.type` `agent_list`, `result.agents[]`.
- `flutter_secure_storage` is pinned to `10.3.1` exactly: its android module is compileSdk 36. `11.x` wants 37 and the store SDK only carries `android-37.0`.
- Verify an apk with `aapt2 dump badging` and `apksigner verify --print-certs` from the build-tools 37.0.0 store path before parking it.
