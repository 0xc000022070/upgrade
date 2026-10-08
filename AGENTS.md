SSH connection lifecycle follows the policy header in `lib/platform/ssh/connection_supervisor.dart`; read it before changing how a connection opens, closes or retries.

# Remote host development

Use the NixOS VM as Upgrade's integrated remote computer. Build Upgrade and drive
the Android emulator on the development host; do not install Android tooling in
the VM.

1. Start the VM with `nix run .#host-vm`.
2. Run guest commands with `nix run .#host-ssh -- <command>`.
3. The guest project is `/home/dev/Projects/fixture`.
4. Herdr uses the guest session `development`.

The development phone is `pixel_7-api36`, not Faraday. Its Upgrade host entry is:

- name: `UPGRADE HOST VM`
- address: `100.118.60.77:2222`
- user: `dev`
- key: `test-key`

SSH uses TCP 2222. Mosh uses UDP 60920-60935: every guest's `mosh-server` is
pinned to its own sixteen ports, whatever range the app asks for. If the
development host's Tailscale address changes, update the phone entry before
connecting.

## Host scenarios

`nix/host-vm/scenarios.nix` declares one guest per kind of machine the app has
to meet. Boot one with `just host-scenario <name>`, stop it with
`just host-scenario-down <name>`, and run commands with
`nix run .#host-ssh-<name> -- <command>`. Each guest keeps its own disk image,
so a pinned host key survives a reboot.

| name       | ssh  | mosh UDP    | engine | herdr | agent configs      |
|------------|------|-------------|--------|-------|--------------------|
| `bare`     | 2223 | 60936-60951 | no     | no    | none               |
| `herdr`    | 2224 | 60952-60967 | no     | yes   | none               |
| `engine`   | 2225 | 60968-60983 | yes    | no    | writable           |
| `declared` | 2226 | 60984-60999 | yes    | no    | links to the store |

Name the phone entry `SCENARIO <NAME>`, address `100.118.60.77:<ssh>`, user
`dev`, and key `test-key`.

## On rose

The same apps exist for `aarch64-darwin`, where they boot an `aarch64-linux`
guest under HVF. Building that guest needs an `aarch64-linux` builder, which
rose does not have yet, so this path has never booted. Once it does, point the
phone entries at rose's Tailscale address, `100.64.94.121`.
