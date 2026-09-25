{ pkgs, nixos }:

{
  host-vm = nixos.config.system.build.vm;

  host-ssh = pkgs.writeShellApplication {
    name = "dazzle-host-ssh";
    runtimeInputs = [
      pkgs.openssh
      pkgs.sshpass
    ];
    text = ''
      exec sshpass -p dev ssh \
        -p 2222 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        dev@127.0.0.1 "$@"
    '';
  };

  host-vm-runner = pkgs.writeShellApplication {
    name = "dazzle-host-vm";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/dazzle"
      mkdir -p "$state_dir"
      export NIX_DISK_IMAGE="$state_dir/host-vm.qcow2"
      exec ${nixos.config.system.build.vm}/bin/run-${nixos.config.system.name}-vm "$@"
    '';
  };
}
