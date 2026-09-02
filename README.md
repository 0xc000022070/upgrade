# Hotline

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

`phone.toml` declares the target handset. `phone up` builds, installs and
launches; `phone shot --settle` reads the screen back.
