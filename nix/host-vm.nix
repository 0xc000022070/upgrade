{
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  codexFixture = pkgs.codex.overrideAttrs (old: {
    pname = "codex-fixture";
    cargoBuildType = "debug";
    cargoBuildFlags = [
      "--package"
      "codex-cli"
      "--bin"
      "codex"
    ];
    cargoCheckFlags = [
      "--package"
      "codex-cli"
      "--bin"
      "codex"
    ];
    patches = (old.patches or [ ]) ++ [
      ./patches/codex/mock-chatgpt-subscription.patch
      ./patches/codex/mock-api-streaming.patch
    ];
  });

  # Loopback and not 0.0.0.0: nyx runs its own mosh-server on 60001:60999, and a
  # wildcard bind on a port one of those holds fails the whole netdev, so the guest
  # would not boot while the user had a session up.
  moshForwards = map (port: {
    from = "host";
    host.address = "127.0.0.1";
    host.port = port;
    guest.port = port;
    proto = "udp";
  }) (lib.range 60000 61000);
in
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  networking = {
    hostName = "dazzle-host";
    firewall.allowedTCPPorts = [ 22 ];
    firewall.allowedUDPPortRanges = [
      {
        from = 60000;
        to = 61000;
      }
    ];
    firewall.extraCommands = ''
      iptables -A OUTPUT -o lo -j ACCEPT
      iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      iptables -A OUTPUT -p udp --sport 68 --dport 67 -j ACCEPT
      iptables -A OUTPUT -j REJECT
      ip6tables -A OUTPUT -o lo -j ACCEPT
      ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ip6tables -A OUTPUT -j REJECT
    '';
  };

  users.users.dev = {
    isNormalUser = true;
    initialPassword = "dev";
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Fr1T+6b4F464Ii+inLkt3asc9p6gBPrHRpTiyJLRL test-key"
      # The `host` tier's key, private half committed beside this file. Kept apart
      # from `test-key` so the phone's entry goes on working on its own.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHAVni8THzq+Yi2QvpL4MjM4yHxw/bdoThYcZV3yJLqt dazzle-host-vm-test"
    ];
  };

  security.sudo.wheelNeedsPassword = false;
  services.getty.autologinUser = "dev";
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  programs.zsh.enable = true;
  environment.etc."skel/.zshrc".text = ''
    PROMPT='%n@%m:%~%# '
  '';

  environment.systemPackages = [
    codexFixture
    pkgs.git
    pkgs.herdr
    pkgs.mosh
    pkgs.ripgrep
  ];

  systemd.services.dazzle-host-fixture = {
    description = "Seed the Dazzle remote host fixture";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.git ];
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -e /home/dev/.zshrc ]; then
        printf '%s\n' "PROMPT='%n@%m:%~%# '" > /home/dev/.zshrc
      fi

      project=/home/dev/Projects/fixture
      if [ ! -d "$project/.git" ]; then
        mkdir -p "$project"
        git -C "$project" init -b main
        git -C "$project" config user.name fixture
        git -C "$project" config user.email fixture@localhost
        printf 'Dazzle remote host fixture\n' > "$project/README"
        git -C "$project" add README
        git -C "$project" commit -m 'initial fixture'
      fi
    '';
  };

  virtualisation = {
    cores = 2;
    memorySize = 2048;
    diskSize = 8192;
    graphics = false;
    useNixStoreImage = true;
    mountHostNixStore = false;
    writableStore = true;
    writableStoreUseTmpfs = false;
    useHostCerts = false;
    restrictNetwork = false;
    sharedDirectories = lib.mkForce { };
    forwardPorts = [
      {
        from = "host";
        host.address = "0.0.0.0";
        host.port = 2222;
        guest.port = 22;
      }
    ]
    ++ moshForwards;
  };

  system.stateVersion = "25.11";
}
