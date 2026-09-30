{
  description = "Dazzle — local-first personal control plane (Flutter)";

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
      pkgs = import nixpkgs { inherit system; };

      engineModule =
        path:
        { pkgs, lib, ... }:
        {
          imports = [ path ];
          services.dazzle-engine.package =
            lib.mkDefault
              self.packages.${pkgs.stdenv.hostPlatform.system}.engine;
        };

      hostScenarios = import ./nix/host-vm/scenarios.nix;
      hostName = name: if name == "full" then "dazzle-host" else "dazzle-host-${name}";
      hostTools = lib.concatMapAttrs (
        name: scenario:
        import ./nix/host-vm/tools.nix {
          inherit pkgs name;
          inherit (scenario) sshPort;
          nixos = self.nixosConfigurations.${hostName name};
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
      })) { ${system} = hostTools; };

      apps.${system} = lib.concatMapAttrs (
        name: _:
        let
          suffix = if name == "full" then "" else "-${name}";
        in
        {
          "host-vm${suffix}" =
            app hostTools."host-vm-runner${suffix}"
              "Run the ${name} remote host fixture for Dazzle";
          "host-up${suffix}" =
            app hostTools."host-up${suffix}"
              "Boot the ${name} remote host fixture detached";
          "host-ssh${suffix}" =
            app hostTools."host-ssh${suffix}"
              "Run a command on the ${name} remote host fixture";
        }
      ) hostScenarios;

      nixosConfigurations = lib.mapAttrs' (
        name: scenario:
        lib.nameValuePair (hostName name) (
          lib.nixosSystem {
            inherit system;
            modules = [
              ./nix/host-vm/configuration.nix
              self.nixosModules.dazzle-engine
              {
                dazzleHost = scenario // {
                  inherit name;
                };
              }
            ];
          }
        )
      ) hostScenarios;

      # The engine is declared by the owner of a machine, never installed by the
      # app, so the modules are the only supported way onto a host.
      nixosModules = rec {
        dazzle-engine = engineModule ./nix/engine/nixos.nix;
        default = dazzle-engine;
      };

      darwinModules = rec {
        dazzle-engine = engineModule ./nix/engine/darwin.nix;
        default = dazzle-engine;
      };

      homeModules = rec {
        dazzle-engine = engineModule ./nix/engine/home.nix;
        default = dazzle-engine;
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
