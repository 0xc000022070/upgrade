# Faraday

Faraday is the user's Pixel 10 Pro Fold. It holds real data. Review surface only.

- Push only at a phase close or on the user's word, never per checkpoint.
- Fetch the parked apk: `scp rose:/tmp/hotline-v<N>.apk <scratch>/`.
- Verify before install, both from the android-sdk-build-tools 37.0.0 store path
  (`/nix/store/*-android-sdk-build-tools-37.0.0/libexec/android-sdk/build-tools/37.0.0/`):
  - `aapt2 dump badging <apk>` shows the expected `versionCode`.
  - `apksigner verify --print-certs <apk>` shows SHA-256
    `d6b7cdfb8d0a5c0017e317b7db27f3fb3ce0b3f650f28ca6b989c4582f5d7e5e`.
- Install in place only: `adb -s faraday:5555 install -r <apk>`.
- Confirm: `adb -s faraday:5555 shell dumpsys package dev.luisnquin.hotline` shows the new `versionCode`, `firstInstallTime=2026-09-01 15:08:22` unchanged, `signatures:[90230224]`.
- Never tap, type, `uninstall`, `pm clear`, or install a differently signed apk on it.
- Record the push in memory with the lastUpdateTime.
