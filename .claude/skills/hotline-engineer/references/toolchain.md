# Toolchain

Everything runs through the flake: `nix develop -c <cmd>` or `just`.

- `just gen` codegen, `just analyze`, `just fmt`.
- `just apk` debug arm64. `just apk-release <version> <code>` release arm64; pass the build number from `pubspec.yaml`, a bare release build reports versionCode 1.
- `just run` hot reload against the emulator on rose over an ssh-forwarded adb socket. `kill -USR1 $(cat build/run.pid)` reloads, `-USR2` restarts. This is the inner loop; apks are for checkpoints.
- `phone` CLI for screenshots, taps, waits and recordings on the emulator. `phone shot --settle` after an action, never a sleep. `phone --help` and `phone help <verb>` carry the rest.
- Device: `emulator-5554` on rose, `pixel_7-api36`, arm64. Fold is simulated with `adb shell wm size 2232x2310` and `wm size reset`.
- The emulator also hosts another app. A stray back key can foreground it; relaunch Hotline with `am start`, touch nothing else.
- `flutter_secure_storage` is pinned to `10.3.1` exactly: its android module is compileSdk 36. `11.x` wants 37 and the store SDK only carries `android-37.0`.
- Verify an apk with `aapt2 dump badging` and `apksigner verify --print-certs` from the build-tools 37.0.0 store path before parking it.
