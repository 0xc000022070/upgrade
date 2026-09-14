# Remote host development

Use the NixOS VM as Dazzle's integrated remote computer. Build Dazzle and drive
the Android emulator on the development host; do not install Android tooling in
the VM.

1. Start the VM with `nix run .#host-vm`.
2. Run guest commands with `nix run .#host-ssh -- <command>`.
3. The guest project is `/home/dev/Projects/fixture`.
4. Herdr uses the guest session `development`.

The development phone is `pixel_7-api36`, not Faraday. Its Dazzle host entry is:

- name: `DAZZLE HOST VM`
- address: `100.118.60.77:2222`
- user: `dev`
- key: `test-key`

SSH uses TCP 2222. Mosh uses UDP 60000-61000. If the development host's
Tailscale address changes, update the phone entry before connecting.
