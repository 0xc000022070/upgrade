{
  description = "Dazzle — local-first personal control plane (Flutter)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # The engine is a plain Rust binary and builds anywhere; the dev shell
      # cannot follow it onto darwin, because it composes an unfree Android SDK.
      # Apple Silicon only: nixpkgs 26.11 dropped x86_64-darwin outright, and
      # naming it here makes the whole flake refuse to evaluate.
      engineSystems = systems ++ [ "aarch64-darwin" ];

      forEngineSystems =
        f: nixpkgs.lib.genAttrs engineSystems (system: f (import nixpkgs { inherit system; }));

      engineFor = pkgs: self.packages.${pkgs.stdenv.hostPlatform.system}.engine;

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
                android_sdk.accept_license = true;
              };
            }
          )
        );

      hostVmPackages =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        in
        {
          host-vm = self.nixosConfigurations.dazzle-host.config.system.build.vm;

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
              exec ${self.packages.x86_64-linux.host-vm}/bin/run-${self.nixosConfigurations.dazzle-host.config.system.name}-vm "$@"
            '';
          };
        };
    in
    {
      nixosConfigurations.dazzle-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./nix/host-vm.nix
          self.nixosModules.dazzle-engine
        ];
      };

      # The host-VM fixtures are x86_64-linux only, so they are merged onto the
      # engine's four systems rather than declared beside them.
      packages = nixpkgs.lib.recursiveUpdate (forEngineSystems (pkgs: {
        engine = pkgs.callPackage ./nix/engine.nix { };
      })) { x86_64-linux = hostVmPackages; };

      apps.x86_64-linux.host-vm = {
        type = "app";
        program = "${self.packages.x86_64-linux.host-vm-runner}/bin/dazzle-host-vm";
        meta.description = "Run a remote host fixture for Dazzle";
      };

      apps.x86_64-linux.host-ssh = {
        type = "app";
        program = "${self.packages.x86_64-linux.host-ssh}/bin/dazzle-host-ssh";
        meta.description = "Run a command on the Dazzle remote host fixture";
      };

      # The engine is declared by the owner of a machine, never installed by the
      # app, so the module is the only supported way onto a host.
      nixosModules.dazzle-engine =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/engine-module.nix ];
          services.dazzle-engine.package = lib.mkDefault (engineFor pkgs);
        };

      nixosModules.default = self.nixosModules.dazzle-engine;

      darwinModules.dazzle-engine =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/engine-darwin.nix ];
          services.dazzle-engine.package = lib.mkDefault (engineFor pkgs);
        };

      darwinModules.default = self.darwinModules.dazzle-engine;

      homeModules.dazzle-engine =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/engine-home.nix ];
          services.dazzle-engine.package = lib.mkDefault (engineFor pkgs);
        };

      homeModules.default = self.homeModules.dazzle-engine;

      devShells = forAllSystems (
        pkgs:
        let
          android = pkgs.androidenv.composeAndroidPackages {
            cmdLineToolsVersion = "22.0";
            platformToolsVersion = "37.0.1";
            # jni (a transitive drift dependency) pins compileSdk 35; gradle cannot
            # install a missing platform into the read-only store SDK.
            platformVersions = [
              "35"
              "36"
              "37.0"
            ];
            buildToolsVersions = [
              "35.0.1"
              "36.0.0"
              "37.0.0"
            ];
            includeNDK = true;
            ndkVersions = [ "28.2.13676358" ];
            # AGP installs its own CMake for externalNativeBuild; 3.22.1 is its
            # default and must be present, since the store SDK cannot grow one.
            cmakeVersions = [
              "3.22.1"
              "3.31.6"
            ];
            includeEmulator = false;
            includeSystemImages = false;

            # flutter doctor checks the whole accepted-license set, not just the SDK one.
            extraLicenses = [
              "android-sdk-preview-license"
              "android-sdk-arm-dbt-license"
              "android-googletv-license"
              "android-googlexr-license"
              "google-gdk-license"
              "intel-android-extra-license"
              "intel-android-sysimage-license"
              "mips-android-sysimage-license"
              "microxr-sysimage-license"
            ];
          };

          sdkRoot = "${android.androidsdk}/libexec/android-sdk";
          ndkRoot = "${sdkRoot}/ndk/28.2.13676358";
          jdk = pkgs.jdk21;

          ghosttySrc = pkgs.fetchFromGitHub {
            owner = "ghostty-org";
            repo = "ghostty";
            rev = "349f026087d948f8f898dca3231ff91438f83ab8";
            hash = "sha256-0/eonC+DEqnQpkKZP+CkEI9saK90i3/FnMeNmO9NeIw=";
          };
        in
        {
          default = pkgs.mkShell {
            name = "dazzle";

            packages = [
              pkgs.flutter
              pkgs.dart
              pkgs.sqlite
              pkgs.just
              jdk
              pkgs.cargo
              pkgs.rustc
              pkgs.clippy
              pkgs.rustfmt
              pkgs.zig
            ];

            # Linux desktop target: flutter drives cmake/ninja/clang against GTK.
            nativeBuildInputs = [
              pkgs.pkg-config
              pkgs.cmake
              pkgs.ninja
              pkgs.clang
            ];

            buildInputs = [
              pkgs.gtk3
              pkgs.glib
              pkgs.pcre2
              pkgs.libepoxy
              pkgs.libxkbcommon
              pkgs.libsecret
              pkgs.jsoncpp
              pkgs.dbus
              pkgs.at-spi2-core
              pkgs.libxtst
              pkgs.util-linux
              pkgs.xz
            ];

            # sqlite3 dart package dlopen()s libsqlite3 at runtime on desktop.
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.sqlite ];

            ANDROID_HOME = sdkRoot;
            ANDROID_SDK_ROOT = sdkRoot;
            ANDROID_NDK_ROOT = ndkRoot;
            ANDROID_NDK_HOME = ndkRoot;
            GHOSTTY_SRC = ghosttySrc;
            JAVA_HOME = "${jdk}";

            shellHook = ''
              export DAZZLE_BUILD="$(${pkgs.git}/bin/git rev-parse --short HEAD 2>/dev/null || echo dev)"

              # Only these two keys are rewritten, because store paths move with the
              # flake lock. Every other key is kept: `flutter build` writes
              # flutter.versionCode into the same file for gradle to read back, and a
              # shell opening mid-build used to truncate it, costing the apk its version.
              if [ -d android ]; then
                props=android/local.properties
                tmp=$(mktemp "$props.XXXXXX")
                {
                  printf 'sdk.dir=%s\n' ${sdkRoot}
                  printf 'flutter.sdk=%s\n' ${pkgs.flutter}
                  if [ -e "$props" ]; then
                    ${pkgs.gnugrep}/bin/grep -vE '^(sdk\.dir|flutter\.sdk)=' "$props" || true
                  fi
                } > "$tmp"
                chmod 644 "$tmp"
                mv -f "$tmp" "$props"
              fi
            '';
          };
        }
      );
    };
}
