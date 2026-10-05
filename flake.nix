{
  description = "Upgrade — local-first personal control plane (Flutter)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # The engine is a plain Rust binary and builds anywhere; the dev shell
      # cannot follow it onto darwin, because it composes an unfree Android SDK.
      # Apple Silicon only: nixpkgs 26.11 dropped x86_64-darwin outright, and
      # naming it here makes the whole flake refuse to evaluate.
      engineSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      system = "x86_64-linux";

      engineModule =
        path:
        { pkgs, lib, ... }:
        {
          imports = [ path ];
          services.upgrade-engine.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.engine;
        };

      hostScenarios = import ./nix/host-vm/scenarios.nix;
      hostName = name: if name == "full" then "upgrade-host" else "upgrade-host-${name}";
      guestSystems = {
        x86_64-linux = "x86_64-linux";
        aarch64-darwin = "aarch64-linux";
      };
      guest =
        hostSystem: name: scenario:
        lib.nixosSystem {
          system = guestSystems.${hostSystem};
          modules = [
            ./nix/host-vm/configuration.nix
            self.nixosModules.upgrade-engine
            {
              upgradeHost = scenario // {
                inherit name;
              };
              virtualisation.host.pkgs = nixpkgs.legacyPackages.${hostSystem};
            }
          ];
        };
      hostTools =
        hostSystem:
        lib.concatMapAttrs (
          name: scenario:
          import ./nix/host-vm/tools.nix {
            pkgs = nixpkgs.legacyPackages.${hostSystem};
            inherit name;
            inherit (scenario) sshPort;
            nixos = guest hostSystem name scenario;
          }
        ) hostScenarios;

      app = pkg: description: {
        type = "app";
        program = lib.getExe pkg;
        meta = { inherit description; };
      };
    in
    {
      packages = lib.recursiveUpdate (lib.genAttrs engineSystems (system: {
        engine = nixpkgs.legacyPackages.${system}.callPackage ./nix/engine/package.nix { };
      })) (lib.mapAttrs (hostSystem: _: hostTools hostSystem) guestSystems);

      apps = lib.mapAttrs (
        hostSystem: _:
        let
          tools = hostTools hostSystem;
        in
        lib.concatMapAttrs (
          name: _:
          let
            suffix = if name == "full" then "" else "-${name}";
          in
          {
            "host-vm${suffix}" =
              app tools."host-vm-runner${suffix}"
                "Run the ${name} remote host fixture for Upgrade";
            "host-up${suffix}" = app tools."host-up${suffix}" "Boot the ${name} remote host fixture detached";
            "host-ssh${suffix}" =
              app tools."host-ssh${suffix}"
                "Run a command on the ${name} remote host fixture";
          }
        ) hostScenarios
      ) guestSystems;

      nixosConfigurations = lib.mapAttrs' (
        name: scenario: lib.nameValuePair (hostName name) (guest system name scenario)
      ) hostScenarios;

      # The engine is declared by the owner of a machine, never installed by the
      # app, so the modules are the only supported way onto a host.
      nixosModules = rec {
        upgrade-engine = engineModule ./nix/engine/nixos.nix;
        default = upgrade-engine;
      };

      darwinModules = rec {
        upgrade-engine = engineModule ./nix/engine/darwin.nix;
        default = upgrade-engine;
      };

      homeModules = rec {
        upgrade-engine = engineModule ./nix/engine/home.nix;
        default = upgrade-engine;
      };

      devShells.${system}.default = import ./nix/dev-shell.nix {
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };
      };
    };
}
