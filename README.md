# Spectacle

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

## Host setup

Spectacle uses one ordinary SSH key for shells, remote commands, and the VNC
tunnel. Copy the public key shown by the app into `~/.ssh/authorized_keys`
without a forced `command=`, `restrict`, or `permitopen` prefix. The key has the
same access as an interactive login for that account.

The AGENTS panel and SEND need `herdr` on the non-interactive SSH `PATH` and a
session named `hub`. Spectacle scans `~/Projects`, `~/.dotfiles`, and `~/src` for
Git checkouts. Clipboard attachments need `wl-copy` and `wl-paste` on Wayland,
`xclip` on X11, or `osascript` on macOS.

An SSH login on Linux does not inherit the desktop display. Put this in the
login shell setup when agents started from Spectacle must read image attachments:

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
