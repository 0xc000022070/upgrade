# Faraday

Faraday is the user's Pixel 10 Pro Fold. It holds real data. Review surface only.

- Push at every shipped feature automatically, without asking (user, 2026-09-03).
- Build it yourself from the committed tree: `nix develop path:$PWD -c just apk-release <version> <code>` with the build number from `pubspec.yaml`; park a copy at `rose:/tmp/dazzle-v<N>.apk`.
- If a builder already parked one, fetch it: `scp rose:/tmp/dazzle-v<N>.apk <scratch>/`.
- Verify before install, both from the android-sdk-build-tools 37.0.0 store path
  (`/nix/store/*-android-sdk-build-tools-37.0.0/libexec/android-sdk/build-tools/37.0.0/`):
  - `aapt2 dump badging <apk>` shows the expected `versionCode`.
  - `apksigner verify --print-certs <apk>` shows SHA-256
    `d6b7cdfb8d0a5c0017e317b7db27f3fb3ce0b3f650f28ca6b989c4582f5d7e5e`.
- Drive the device with the `phone` CLI, never raw adb. `phone device list` must show faraday `attached/tcp`; if it is `known` or `offline`, `phone device connect faraday`.
- Install in place only: `phone app install -t faraday <apk>`. Never `phone up` against faraday: it launches the app, and the user opens it themselves.
- Confirm (the one thing `phone` has no verb for): `adb -s faraday:5555 shell dumpsys package dev.luisnquin.dazzle` shows the new `versionCode`, `firstInstallTime=2026-09-01 15:08:22` unchanged, `signatures:[90230224]`.
- Never tap, type, `uninstall`, `pm clear`, or install a differently signed apk on it.
- Record the push in memory with the lastUpdateTime.
