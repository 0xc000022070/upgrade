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

`phone.toml` declares the target handset. `phone up` builds, installs and
launches; `phone shot --settle` reads the screen back.

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
under `$XDG_RUNTIME_DIR/pinentry-gate/tty`, and the pinentry writes the request
into every marked terminal while also asking on the computer. The first answer
wins.

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
