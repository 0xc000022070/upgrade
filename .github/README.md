# Upgrade

Run and supervise coding agents from your phone.

Upgrade is a mobile control plane for autonomous work on remote computers. It
connects to the machines where the work already runs, keeps their agent sessions
within reach, and gives you the controls needed to inspect and redirect that
work without returning to a desktop.

The project asks one question:

> Can a phone become the primary computer for directing software work?

The phone does not need to compile the project or imitate a desktop IDE. Remote
hosts provide the compute. Upgrade provides intent, context, observation,
approval, and intervention.

## The work loop

Upgrade aims to support the complete loop from a phone:

1. Choose a host and workspace.
2. Start work now or schedule it for later.
3. Follow the agent and receive an alert when it needs attention.
4. Answer authorization requests or supply more context.
5. Inspect the repository and review the resulting diff.
6. Redirect, retry, accept, or continue the work.

The human remains responsible for judgment and authority. The agent does not
need continuous supervision between those decisions.

## The foundations

| Block | Job |
| --- | --- |
| Hosts | Define where work runs, how Upgrade connects, and which credentials it may use. |
| SSH and Mosh | Provide ordinary shells, remote commands, durable agent attachment, and roaming between networks. |
| Workspaces | Bind a Git checkout to its files, changes, commands, and agents. |
| Code tools | Expose repository state and diffs for review and small interventions. |
| VNC | Provide an escape hatch for software that has no useful terminal or machine interface. |
| Plugins | Add controls and workflows without putting every domain into the core app. |
| Scheduling | Let work begin and continue while the phone is closed and the human is elsewhere. |

These blocks are not separate product goals. They support one job: keep remote
work moving while preserving control on a mobile device.

## What exists now

Upgrade is an Android-first Flutter application. It currently includes:

- local host, key, project, and task data backed by SQLite;
- SSH shells with Mosh roaming and SSH fallback;
- persistent attachment to agents managed by Herdr;
- agent state, blocked-work alerts, and authorization requests;
- remote workspace discovery, source browsing, and Git diff review;
- VNC access through an SSH tunnel;
- transfer of text, links, and images into remote work;
- native and sandboxed Luau plugins with declared capabilities;
- a plugin that schedules agent work on a host;
- encrypted export and import for moving host configuration between phones.

## Privacy

Upgrade has no tracking, analytics, account service, or Upgrade-operated backend.
It does not collect usage data, build a user profile, or relay sessions through
project infrastructure.

Host configuration, pinned host keys, private SSH keys, projects, and plugin
data stay on the phone. Upgrade connects directly to hosts selected by the user.
Plugin installation fetches source only from a repository or index the user
adds. An encrypted configuration export leaves the phone only through the
system share flow chosen by the user.

Remote hosts and configured source providers remain responsible for data sent
to them. Upgrade does not copy that data to a separate service.

## Plugins and control

A phone-sized interface should not impose a fixed set of controls. Plugins can
add pages, home cards, input actions, datasets, and host-backed operations.

Downloaded plugins run as Luau source inside bounded worker isolates. Their
manifests declare capabilities and dependencies before installation. Plugins do
not receive arbitrary filesystem, socket, or shell access. Host operations pass
through APIs owned by Upgrade.

The agent schedules plugin demonstrates the intended model. A plugin defines
when work should run and asks the host scheduler to run it. The work continues
off-device. Upgrade remains the place to inspect its state and intervene.

## Product boundary

Upgrade is not trying to reproduce every desktop tool on a smaller screen. It
needs enough terminal, code, screen, and plugin support to remove forced trips
back to the desktop.

The target experience is concrete:

1. Define and schedule work on the phone.
2. Close the phone while agents run on remote hosts.
3. Return when Upgrade reports a decision or authorization request.
4. Review the result and continue from the phone.

That is the MVP test. No desktop is required, and remote work remains visible
and controllable.

## Development

The Nix flake provides Flutter, Dart, SQLite, a JDK, and the Android SDK.

```sh
direnv allow
just pub-build
just gen
just analyze
just apk
```

Use the NixOS VM as the integrated remote host:

```sh
nix run .#host-vm
nix run .#host-ssh -- <command>
```

The detailed toolchain, device loop, plugin model, limits, and host setup remain
documented in the [operator README](../README.md).
