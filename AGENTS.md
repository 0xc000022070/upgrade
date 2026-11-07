SSH connection lifecycle follows the policy header in `lib/platform/ssh/connection_supervisor.dart`; read it before changing how a connection opens, closes or retries.

# Remote host development

Use the NixOS VM as Upgrade's integrated remote computer. Build Upgrade and drive
the Android emulator on the development host; do not install Android tooling in
the VM.

1. Start the VM with `nix run .#host-vm`.
2. Run guest commands with `nix run .#host-ssh -- <command>`.
3. The guest project is `/home/dev/Projects/fixture`.
4. Herdr uses the guest session `development`.

Machine names and addresses for this checkout live in `CLAUDE.local.md`
(gitignored); `<host-ip>` below is the development host's address as the phone
reaches it, usually its Tailscale IP.

The development phone is `pixel_7-api36`, not the review handset. Its Upgrade
host entry is:

- name: `UPGRADE HOST VM`
- address: `<host-ip>:2222`
- user: `dev`
- key: `test-key`

`just phone-host <ip> [scenario]` writes that entry into the debug build adb
picks, with no form typed. Pass the bare IP (`<host-ip>`); the scenario
supplies the port. It refuses an address that does not answer with
the declared host key, `SHA256:hDVbIZXceJXxmv9IiBarvzZx3utci+tvV5gyo8ya0Wc`
(`nix/host-vm/fixtures/host_vm_host_key`, shared by every guest), and keeps
the phone's private key in `$XDG_STATE_HOME/upgrade`, out of the repo.

SSH uses TCP 2222. Mosh uses UDP 60920-60935: every guest's `mosh-server` is
pinned to its own sixteen ports, whatever range the app asks for. The default
guest also serves a desktop, a ticking clock and an xterm, by VNC on its
loopback port 5900; the app's `DESKTOP` reaches it through the SSH tunnel. If the
development host's Tailscale address changes, update the phone entry before
connecting.

## Host scenarios

`nix/host-vm/scenarios.nix` declares one guest per kind of machine the app has
to meet. Boot one with `just host-vm <name>`, stop it with
`just host-vm-down <name>`, and run commands with
`nix run .#host-ssh-<name> -- <command>`. Each guest keeps its own disk image,
so a pinned host key survives a reboot.

| name       | ssh  | mosh UDP    | engine | herdr | agent configs      |
|------------|------|-------------|--------|-------|--------------------|
| `bare`     | 2223 | 60936-60951 | no     | no    | none               |
| `herdr`    | 2224 | 60952-60967 | no     | yes   | none               |
| `engine`   | 2225 | 60968-60983 | yes    | no    | writable           |
| `declared` | 2226 | 60984-60999 | yes    | no    | links to the store |

Name the phone entry `SCENARIO <NAME>`, address `<host-ip>:<ssh>`, user
`dev`, and key `test-key`.

## On an Apple silicon Mac

The same apps exist for `aarch64-darwin`, where they boot an `aarch64-linux`
guest under HVF. Building that guest needs an `aarch64-linux` builder, which
the Mac may not have, so this path has never booted. Once it does, point the
phone entries at the Mac's address.
