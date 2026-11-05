# Upgrade

An Android app for people who run their own machines. From the phone you open
shells on your hosts over SSH or Mosh, watch and answer the coding agents
running there, reach a host's desktop, and build your own tool interfaces in
Luau that run commands you declared on hosts you chose.

There is no backend, account or sync. Hosts, keys, projects and plugins live on
the phone; hosts are reached directly over SSH. The phone reaches a host with
exactly the authority of the SSH account you give it, and plugins get less: only
the operations they declare, after a native review and a per-host consent.

Building the app and working on it: [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).
Product rulings: [docs/SPEC.md](docs/SPEC.md).

## One job, end to end

Read a host's network interfaces from a page you wrote.

You need: a host you reach over SSH with `upgraded` declared on it (see
[Engine](#engine)), the phone with that host registered, and an Upgrade checkout
on a development computer.

1. On the development computer, write a two-file package: a manifest that
   declares `ip -brief address` with a ten-second limit, and a Luau page with a
   host picker and four buttons. Check it with `just plugin check <dir>`.
2. Copy the folder to `~/Projects/plugins/network-probe` on the host.
3. On the phone, TOOLS > DEVELOP PLUGIN, pick the host, enter the path, START
   PREVIEW. The card renders from fixtures. Tap INSTALL; the native review shows
   the exact command and its limit.
4. OPEN the page, choose the host under Target host, tap READ INTERFACES, and
   allow the consent sheet that names the host account and the command.
5. Tap READ OUTPUT. The page shows `exited` and the host's interface rows.

This path was verified on a physical phone (release build) against the
development VM on 2026-11-04, including a non-zero exit, a cancellation and
cancelling a running command by disabling the plugin. The copyable files and
every step are in [docs/TOOL-TUTORIAL.md](docs/TOOL-TUTORIAL.md).

## Install

Release APKs go to
[GitHub releases](https://github.com/0xc000022070/upgrade/releases). Or build
one from source: `just apk` (debug) or `just apk-release`
inside the flake's dev shell, as described in
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). Android only.

## First SSH connection

1. MACHINES > HOSTS, then ADD HOST in the ADD A MACHINE panel. Fill NAME,
   ADDRESS (IP or hostname), PORT and USER.
2. Under `[ KEY ]`, pick a key or CREATE SSH KEY (NEW KEY, a name, CREATE KEY).
   CREATE HOST. It dials the host at once (the key need not be installed yet)
   and raises `NEW HOST KEY` with its KEY TYPE and FINGERPRINT. Compare it with
   the host's own (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the
   host) and TRUST. The key is pinned; a later different key raises
   `HOST KEY CHANGED` with the STORED KEY and the OFFERED KEY, and KEEP OLD or
   REPLACE. If that dial failed or you declined, the host is saved unpinned and
   its row keeps VERIFY: tap it once the host answers.
3. Put the public key on the host. MACHINES toolbar > MANAGE SSH KEYS > the key
   > `[ INSTALL ]` > COPY copies one shell line that appends the key to
   `~/.ssh/authorized_keys` (creating `~/.ssh` with mode 700, the file with
   600, and skipping a key already there). Run it on the host as that user,
   from any session you already have. See [Host setup](#host-setup) for what
   the key must not carry.
4. Tap SHELL. The picker offers LOGIN SHELL, plus herdr and tmux sessions when
   the host has them. A tab opens.

The host row's LINK line probes the SSH port: `<SOFTWARE> · <n> MS` when it
answers, otherwise NO ROUTE, UNRESOLVED, REFUSED or NO BANNER. A failed VERIFY
names why: NO KEY, KEY CHANGED, NO ANSWER, NO ROUTE or FAILED.

## Returning to a session

- The host row reads `SHELL · N OPEN` while tabs exist. SHELL resumes the last
  running tab. When every tab has exited, it asks how to start a new one; exited
  tabs stay on the strip.
- With `mosh-server` on the host, a live tab keeps roaming across network
  changes. Without it, or when UDP is blocked, the same tab uses SSH.
- After an app restart, tabs come back as fresh login shells, not the old
  processes. A tab attached to a herdr pane reattaches that pane. Hosts without
  a pinned key are not dialed unattended, and tabs of deleted hosts are dropped.

Shell tabs were not part of the 2026-11-04 device review.

## What it does

Status words: **verified** means exercised on a release build: on a physical
phone in the 2026-11-04 review, or in the 2026-11-05 follow-up on the devices
the row names; **implemented** means in the code and its tests but not
covered by either; **planned** means written down as a proposal only.

### Phone only

| capability | status |
|---|---|
| Projects, goals, tasks, notes and drops | implemented |
| Board (bundled Luau plugin) | verified: navigation and saving a note |
| Luau Home cards that never contact a host | verified: authoring, preview, failure and recovery on fixtures |
| Chat: end-to-end encrypted, phone to phone, no server | verified: an emulator and a physical phone joined by an invitation code, messages delivered both ways |
| LINUX ON THIS PHONE (MACHINES > ADD A MACHINE), without root | verified on an emulator: install and a shell |
| Encrypted bundle to move the phone's data ([Backup](#backup-and-a-second-phone)) | verified: an emulator to a physical phone, and to a fresh emulator install |

### Ordinary SSH

Everything here uses only the SSH account and its normal login path.

| capability | status |
|---|---|
| Host key pinning, VERIFY, the host key sheets | implemented; used throughout the 2026-11-04 review |
| Shell tabs, restored after restart | implemented |
| MACHINES > CODE: Git checkouts under `~/Projects`, `~/.dotfiles`, `~/src`; files, diffs, history | verified: navigation of Code, diff and history |
| Clipboard attachments | implemented |
| Key passphrase prompts from `pinentry-gate`, answered in the app | implemented |

### Optional integrations

Turned on per host under `[ INTEGRATIONS ]` in the host form, and each needs
software on the host ([Host setup](#host-setup)).

| integration | gives | status |
|---|---|---|
| Mosh (no switch; used when `mosh-server` exists) | roaming tabs | implemented |
| HERDR | agents in herdr panes: AGENTS panel, SEND, agent tabs | implemented |
| AGENTS | agents heard from their own hooks | implemented |
| VNC | DESKTOP on the host row, tunnelled through SSH | verified on an emulator: a live desktop, and `FAILED` once the host goes down |
| DEVICES | the host's emulators and simulators | implemented; not verified |

### Engine-backed

These need `upgraded` declared on the host by its owner.

| capability | status |
|---|---|
| Luau `run`: declared commands from a tap, with status, bounded output and cancel | verified: submit, status, output, cancel, non-zero exit, update re-review, online disable; offline cancel and `run.list` not verified |
| Agent tasks (TOOLS > AGENT TASKS, bundled Luau, scheduler service) | verified against a mock agent backend, not a production agent; on an emulator, disabling it while the host is down leaves a pending host pause until RETRY HOST PAUSES reaches the host |
| Luau `agents.answer` (Kanban) | implemented |

### Planned

[docs/STRATEGY.md](docs/STRATEGY.md) is a strategy and
[docs/PLUGIN-SPEC.md](docs/PLUGIN-SPEC.md) a proposed target. Broader network
and tool control, configured instances, general execution, filesystem access
and richer previews described there are not shipped.
[docs/ROADMAP.md](docs/ROADMAP.md) tracks what is next.

### Luau

Plugins are written in [Luau](https://luau.org) 0.738, embedded in the app.
They get the Upgrade SDK and nothing else: no filesystem, sockets, shell, native
modules or arbitrary Lua libraries. A plugin reaches a host only through the
capabilities it declares (`hosts`, `scheduler`, `run`, `agents`), each shown in a
native review before install and asked again per host before first use.
`just plugin docs --out upgrade-sdk.json` writes the pinned SDK inventory:
services, operations, UI schema and diagnostic codes. The reference is
[packages/upgrade_luau/README.md](packages/upgrade_luau/README.md).

## Build your own tool interface

- [docs/TOOL-TUTORIAL.md](docs/TOOL-TUTORIAL.md): a page that runs a declared
  command on a chosen host, reads status and output, handles failure and
  cancellation; and a phone-only card.
- [plugins/templates/phone-card](plugins/templates/phone-card/README.md): the
  template `just plugin init <dir> --id <id> --name <name>` copies, and TOOLS >
  DEVELOP PLUGIN > NEW WORKSPACE writes onto a host.
- [packages/upgrade_luau/README.md](packages/upgrade_luau/README.md): the SDK.

The loop: edit on the development computer, `just plugin check <dir>`, copy the
folder to the host, and keep TOOLS > DEVELOP PLUGIN open on it; the phone
re-renders each new revision and writes its result to
`.upgrade/preview/latest.json`, which `just plugin preview <dir>` reads.

Installed plugins are managed under TOOLS > MANAGE PLUGINS: enable, disable,
usage, removal. ADD installs from a public GitHub repository at a branch, tag or
commit. BROWSE has `[ SOURCES ]`, where you add plugin indexes; none ships by
default. Bundled: Agents, Chat, Drops, Projects and Prompt (native), and Agent
tasks, Board and Kanban (Luau). Details for authors publishing a plugin are in
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md#sources-packages-and-indexes).

## Backup and a second phone

`[ BUNDLE ]` on SYS (HOME toolbar > MORE > SETTINGS) moves the phone's data to
another phone, or to the same phone after a reset or reinstall, as one
encrypted file. There is no server in between.

Export: EXPORT, a passphrase under `[ PASSPHRASE ]` and `[ AGAIN ]`, SEAL. The
system picker saves `upgrade-<date>.bundle`. Errors: `PASSPHRASE MISSING`,
`PASSPHRASES DIFFER`.

Import: IMPORT, pick the file, the passphrase on `IMPORT BUNDLE`. Before
anything is written a confirm counts the contents, for example
`2 HOSTS · 1 KEY · 5 PATHS · 312 ROWS · 4 IMAGES`; IMPORT lands it.

What moves:

- every SSH key with its private half;
- every host with its pinned host key, VNC user and password, and its integrations;
- every registered path;
- projects, goals, tasks, links, attachments, notes, activity, settings,
  dispatches and shell tabs;
- image attachment files.

What does not: LINUX ON THIS PHONE and its host entry, installed plugins and
their datasets, and chat conversations. Those are stored outside the app's main
database.

How it merges: a row with the same id is replaced by the bundle's; a new row is
added; a row only on the phone is left alone. A host's integrations become the
bundle's. If a host's key is in neither the bundle nor the phone, the whole
import is refused. Importing the same file twice gives the same result as once.
Bundles from the app's older name open.

Confirm the result: `[ BUNDLE ]`'s LAST row reads `IMPORTED …` with the same
counts the export showed, MACHINES lists the hosts, and connecting raises no
`NEW HOST KEY`, because the pinned key travelled. Failures show on
that row: `WRONG PASSPHRASE` (or a modified file), `NOT A BUNDLE`,
`NEWER BUNDLE`, `BUNDLE INCOMPLETE`, `NO PICKER`.

The file is Argon2id (64 MiB, 3 passes) plus an XSalsa20-Poly1305 box in a JSON
envelope, so it can sit in a drive or a chat with yourself; the passphrase
cannot. A bundle exported on an emulator (build 836) and imported on a physical
phone and on a fresh emulator install restored the host, its key and its pinned
host key: the shell opened with no `NEW HOST KEY`.

## Troubleshooting

Messages are quoted as the app shows them. Tabs, desktop floats and agent rows
show a lowercase reason line; compact places show the same words in capitals.

### Connecting

| message | check |
|---|---|
| VERIFY reads NO KEY | the host's key has no private half on this phone; pick or create one in the host form |
| `NEW HOST KEY` | first contact. Compare the fingerprint on the host, then TRUST |
| `HOST KEY CHANGED`, VERIFY reads KEY CHANGED | the host offers a different key than the pinned one. Verify the offered fingerprint outside Upgrade before REPLACE |
| `host key unverified` | unattended dials refuse unpinned hosts; VERIFY the host once |
| `<host> unresolved`, LINK UNRESOLVED | the name does not resolve from the phone's network (Tailscale or VPN down?) |
| `<host> unreachable`, NO ROUTE, NO ANSWER, REFUSED | `ssh -p <port> <user>@<address> true` from another machine on the same network |
| `key rejected` | the public key is not in that user's `~/.ssh/authorized_keys`, or sshd rejects it; re-run the INSTALL line |
| `shell refused` | sshd refused the session or its pty request: look for `restrict`, `no-pty` or `command=` on the key line, or `PermitTTY no` |

### Shells

A tab that reconnects over SSH instead of Mosh: run `command -v mosh-server`
in a non-interactive session (`ssh host command -v mosh-server`) and open UDP
60000:61000. `no herdr`: herdr is not on the non-interactive `PATH`; check with
`ssh host command -v herdr`.

### Desktop (VNC)

| message | check |
|---|---|
| `tunnel refused` | nothing listens on the host's `127.0.0.1:5900` (`ss -ltn` on the host), or sshd forbids forwarding (`AllowTcpForwarding`, `permitopen`) |
| `VNC password missing` | the server offers no `None`; fill VNC PASSWORD |
| `VNC username missing` | the server offers only Apple's authentication; fill VNC USER with the macOS account |
| `VNC credentials rejected` | the password, or the user, is wrong |
| `auth unsupported` | the server offers no security type Upgrade speaks |

### Devices

`no emulator or xcrun`, `no avdmanager`, `no system image`,
`no simulator runtime`: the host lacks that tool on the non-interactive `PATH`.
`not booted in 3 min`: the device did not finish booting.

### Plugins and the engine

| message | check |
|---|---|
| `This host has no upgraded installed` | `ssh host command -v upgraded`; the owner declares it ([Engine](#engine)) |
| `This host's engine does not carry …` | the host's engine predates that service; update the flake input |
| `this host denies …` | the host owner's `services.upgraded` deny lists |
| `Verify the host key in MACHINES before connecting` | VERIFY the host and TRUST its key |
| `Host access was not granted` | the consent sheet was cancelled; tap the action again |
| `Commands run only from a tap` | the plugin submitted outside a tap's chain |
| `just plugin check` exits 1 | fix the listed diagnostics; each has a `next:` line |
| CHECK FAILED on DEVELOP PLUGIN | the same diagnostics as `just plugin check`; the last good revision stays shown |
| `just plugin preview` exits 3, `PREVIEW_PENDING` | the phone has not rendered that revision: DEVELOP PLUGIN closed, a different host or path, or the copy did not land |

The full `run` and engine error list is in
[packages/upgrade_luau/README.md](packages/upgrade_luau/README.md#engine-calls).

### Backup

See the failure words under [Backup](#backup-and-a-second-phone).

## Host setup

Upgrade uses one ordinary SSH key for shells, remote commands, and the VNC
tunnel. Copy the public key shown by the app into `~/.ssh/authorized_keys`
without a forced `command=`, `restrict`, or `permitopen` prefix. The key has the
same access as an interactive login for that account.

Install `mosh-server` for roaming shells. Upgrade uses SSH to authenticate and
start Mosh, then moves terminal traffic to Mosh's UDP range. A live Mosh tab
rehomes after the phone changes networks. If the server is absent or UDP cannot
connect, the same tab falls back to SSH. Open UDP ports `60000:61000` on hosts
whose firewall does not already allow Mosh.

Mosh does not depend on a multiplexer. Upgrade never inserts `tmux` around an
ordinary shell: every new or restored tab enters through the host's normal
login path, including any gateway or chooser configured there. Mosh keeps a
live tab roaming between networks; an app process restart opens a fresh shell.
Closing a tab kills only the Mosh server that tab owns.

The AGENTS panel and SEND need `herdr` on the non-interactive SSH `PATH`. Every
running herdr session is listed. An attached agent tab records the exact Herdr
session and pane, then attaches that pane again after a network change or app
restart. Herdr owns that process identity; Upgrade does not put tmux around it.
The pane still uses Mosh transport when the host has `mosh-server`, with SSH as
fallback. SEND starts its agent in herdr's default session, or in the one
session running when the default is not. Upgrade scans `~/Projects`,
`~/.dotfiles`, and `~/src` for Git checkouts. Clipboard attachments need
`wl-copy` and `wl-paste` on Wayland, `xclip` on X11, or `osascript` on macOS.

A passphrase prompt for the SSH key held by gpg-agent is asked for in the app
when the host runs `pinentry-gate` as its pinentry: each shell marks its pty
under `$XDG_RUNTIME_DIR/pinentry-gate/tty` with the pid of the ssh session or
Mosh server holding it, and the pinentry writes the request into every marked
terminal and rings its bell, while also asking on the computer. A Mosh tab
never sees the request itself, only the bell, and asks the host what is open.
The first answer wins, and a tab holding a request keeps asking until the host
says it is gone. The request also rings the shade as `AUTHORIZATION REQUIRED`,
one notification per host on its own channel, and tapping it opens that host's
shell. The pinentry gives up on a request after a window of its own and never
says how long that is, so an ask the app has held five minutes is drawn as one
that may have expired, and an answer written after the host took the request
down is reported as expired rather than passed off as sent.

An SSH login on Linux does not inherit the desktop display. Put this in the
login shell setup when agents started from Upgrade must read image attachments:

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

DESKTOP forwards SSH to `127.0.0.1:5900`. A VNC server that offers RFB security
type `None`, such as `wayvnc`, needs nothing more; authentication stays at SSH,
and `None` is used whenever offered. A server that offers only VNC
Authentication takes the password from the host's `VNC PASSWORD` field. Apple
Screen Sharing offers Apple's own authentication: put the macOS account in
`VNC USER` and its password in `VNC PASSWORD`. With `VNC USER` blank, turn on
"VNC viewers may control screen with password" under Screen Sharing's settings
and put that password in the field.

### Engine

`upgraded` is the host-side engine behind plugin `run`, Agent tasks' scheduler
and `agents.answer`. It is not a daemon: each call reaches it over SSH. The app
never installs it; the host's owner declares it with this flake's module:
`nixosModules.upgraded`, `darwinModules.upgraded` or `homeModules.upgraded`, as
`services.upgraded`. Options include `denyCapabilities` and `denyExec`.
Schedules on Linux need login linger for the account. A host without it answers
plugins with `This host has no upgraded installed`; everything under
[Ordinary SSH](#ordinary-ssh) and the integrations works without it.
