{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  cfg = config.dazzleHost;
  full = cfg.name == "full";

  codexMockPort = 18733;
  codexMockUrl = "http://127.0.0.1:${toString codexMockPort}/backend-api/";

  # Codex never checks the id_token signature, and a last_refresh this far out
  # keeps it from ever refreshing against OpenAI.
  codexAuth =
    let
      claims = builtins.toJSON {
        email = "fixture@localhost";
        "https://api.openai.com/auth" = {
          chatgpt_plan_type = "pro";
          chatgpt_user_id = "fixture-user";
          chatgpt_account_id = "fixture-account";
        };
      };
    in
    pkgs.runCommand "codex-auth.json" { nativeBuildInputs = [ pkgs.jq ]; } ''
      b64() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
      jwt="$(b64 '{"alg":"none","typ":"JWT"}').$(b64 ${lib.escapeShellArg claims}).fixture"
      jq -n --arg jwt "$jwt" '{
        auth_mode: "chatgpt",
        OPENAI_API_KEY: null,
        tokens: {
          id_token: $jwt,
          access_token: "fixture-access-token",
          refresh_token: "fixture-refresh-token",
          account_id: "fixture-account"
        },
        last_refresh: "2099-01-01T00:00:00Z"
      }' > $out
    '';

  moshForwards = map (port: {
    from = "host";
    host.address = "0.0.0.0";
    host.port = port;
    guest.port = port;
    proto = "udp";
  }) (lib.range cfg.mosh.from cfg.mosh.to);

  pinnedMosh = pkgs.writeShellScriptBin "mosh-server" ''
    if [ "''${1-}" = new ]; then
      shift
      kept=()
      while [ $# -gt 0 ] && [ "$1" != -- ]; do
        case "$1" in
          -p) shift; [ $# -gt 0 ] && shift ;;
          -p*) shift ;;
          *) kept+=("$1"); shift ;;
        esac
      done
      exec ${pkgs.mosh}/bin/mosh-server new "''${kept[@]}" -p ${toString cfg.mosh.from}:${toString cfg.mosh.to} "$@"
    fi
    exec ${pkgs.mosh}/bin/mosh-server "$@"
  '';

  declaredConfigs = {
    ".claude/settings.json" = pkgs.writeText "settings.json" (builtins.toJSON { model = "sonnet"; });
    ".codex/hooks.json" = pkgs.writeText "hooks.json" (builtins.toJSON { hooks = { }; });
    ".config/opencode/plugins/dazzle.js" = pkgs.writeText "dazzle.js" "export default {}\n";
  };
in
{
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    ./options.nix
  ];

  networking = {
    hostName = if full then "dazzle-host" else "dazzle-host-${cfg.name}";
    firewall.allowedTCPPorts = [ 22 ];
    firewall.allowedUDPPortRanges = [
      {
        inherit (cfg.mosh) from to;
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

  # The fixture host is a scheduling host. Linger is the half of it that is easy to
  # miss: without it the user's systemd instance stops at logout, and the engine
  # reports the host unsupported rather than installing a timer that would only run
  # while somebody happened to be logged in.
  services.dazzle-engine.enable = cfg.engine;
  users.users.dev = {
    isNormalUser = true;
    linger = true;
    initialPassword = "dev";
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7Fr1T+6b4F464Ii+inLkt3asc9p6gBPrHRpTiyJLRL test-key"
      # The `host` tier's key. Kept apart from `test-key` so the phone's entry
      # goes on working on its own.
      (lib.removeSuffix "\n" (builtins.readFile ./fixtures/host_vm_test_key.pub))
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
    pkgs.git
    pkgs.mosh
    pkgs.ripgrep
  ]
  ++ lib.optional cfg.codex pkgs.codex
  ++ lib.optional cfg.herdr pkgs.herdr
  ++ [ (lib.hiPrio pinnedMosh) ];

  # tmpfiles makes a missing parent root's, and home-manager's are the user's.
  systemd.tmpfiles.settings.dazzle-declared-hooks = lib.mkIf cfg.declaredHooks (
    lib.genAttrs
      (map (dir: "/home/dev/${dir}") [
        ".claude"
        ".codex"
        ".config"
        ".config/opencode"
        ".config/opencode/plugins"
      ])
      (_: {
        d = {
          user = "dev";
          group = "users";
          mode = "0755";
        };
      })
    // lib.mapAttrs' (path: file: {
      name = "/home/dev/${path}";
      value."L+" = {
        argument = "${file}";
        user = "dev";
        group = "users";
      };
    }) declaredConfigs
  );

  environment.etc."codex/config.toml" = lib.mkIf cfg.codex {
    source = (pkgs.formats.toml { }).generate "codex-config.toml" {
      chatgpt_base_url = codexMockUrl;
      model_provider = "fixture";
      model_providers.fixture = {
        name = "Fixture";
        base_url = "${codexMockUrl}codex";
        wire_api = "responses";
        requires_openai_auth = true;
        supports_websockets = false;
      };
      features = {
        apps = false;
        code_mode_host = false;
      };
    };
  };

  systemd.services.codex-mock = lib.mkIf cfg.codex {
    description = "Mock of the OpenAI backend codex talks to";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.perl}/bin/perl ${./codex-mock.pl} ${toString codexMockPort}";
      DynamicUser = true;
      Restart = "on-failure";
    };
  };

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

      ${lib.optionalString cfg.codex ''
        if [ ! -e /home/dev/.codex/auth.json ]; then
          install -D -m 600 ${codexAuth} /home/dev/.codex/auth.json
        fi
      ''}
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
    memorySize = if full then 2048 else 1024;
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
        host.port = cfg.sshPort;
        guest.port = 22;
      }
    ]
    ++ moshForwards;
  };

  system.stateVersion = "25.11";
}
