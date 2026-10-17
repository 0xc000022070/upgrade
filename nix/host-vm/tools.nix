{
  pkgs,
  nixos,
  name,
  sshPort,
}:

let
  inherit (pkgs) lib;
  full = name == "full";
  suffix = if full then "" else "-${name}";
  port = toString sshPort;
  vmName = nixos.config.system.name;
  runner = "${nixos.config.system.build.vm}/bin/run-${vmName}-vm";
in
{
  "host-vm${suffix}" = nixos.config.system.build.vm;

  "host-ssh${suffix}" = pkgs.writeShellApplication {
    name = "striked-host-ssh${suffix}";
    runtimeInputs = [
      pkgs.openssh
      pkgs.sshpass
    ];
    text = ''
      exec sshpass -p dev ssh \
        -p ${port} \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        dev@127.0.0.1 "$@"
    '';
  };

  "host-vm-runner${suffix}" = pkgs.writeShellApplication {
    name = "striked-host-vm${suffix}";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/striked"
      mkdir -p "$state_dir"
      export NIX_DISK_IMAGE="$state_dir/host-vm${suffix}.qcow2"
      exec ${runner} "$@"
    '';
  };

  "host-up${suffix}" = pkgs.writeShellApplication {
    name = "striked-host-up${suffix}";
    runtimeInputs = [
      pkgs.coreutils
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.procps
      pkgs.util-linux
    ];
    text = ''
      probe() { bash -c 'exec 3<>/dev/tcp/127.0.0.1/${port} && head -c 3 <&3 | grep -q SSH' 2>/dev/null; }
      if probe; then echo "${vmName}: up on ${port}"; exit 0; fi
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/striked"
      mkdir -p "$state_dir"
      log="''${TMPDIR:-/tmp}/${vmName}.log"
      echo "${vmName}: booting, log $log"
      NIX_DISK_IMAGE="$state_dir/host-vm${suffix}.qcow2" \
        nohup ${lib.optionalString pkgs.stdenv.isLinux "setsid "}${runner} -nographic </dev/null >"$log" 2>&1 &
      vm=$!
      for _ in $(seq 1 180); do
        if probe; then echo "${vmName}: up on ${port}"; exit 0; fi
        if ! kill -0 "$vm" 2>/dev/null && ! pgrep -f 'qemu-system-.* -name ${vmName}( |$)' >/dev/null; then
          echo "${vmName}: the guest exited while booting; see $log" >&2
          tail -n 3 "$log" >&2
          exit 1
        fi
        sleep 2
      done
      echo "${vmName}: no sshd on ${port} after six minutes; see $log" >&2
      exit 1
    '';
  };
}
