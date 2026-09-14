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
    in
    {
      nixosConfigurations.dazzle-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./nix/host-vm.nix ];
      };

      packages.x86_64-linux.host-vm = self.nixosConfigurations.dazzle-host.config.system.build.vm;

      packages.x86_64-linux.host-ssh =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        in
        pkgs.writeShellApplication {
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

      packages.x86_64-linux.host-vm-runner =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          vm = self.packages.x86_64-linux.host-vm;
        in
        pkgs.writeShellApplication {
          name = "dazzle-host-vm";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/dazzle"
            mkdir -p "$state_dir"
            export NIX_DISK_IMAGE="$state_dir/host-vm.qcow2"
            exec ${vm}/bin/run-${self.nixosConfigurations.dazzle-host.config.system.name}-vm "$@"
          '';
        };

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
          jdk = pkgs.jdk21;
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
            ANDROID_NDK_ROOT = "${sdkRoot}/ndk/28.2.13676358";
            JAVA_HOME = "${jdk}";

            shellHook = ''
              # SPEC.md §39.16's build line. Computed on every `nix develop`,
              # including the `nix develop -c` that phone.toml builds through, so
              # the sha a binary is stamped with is the sha it was built from.
              # `dev` outside a checkout, which is what an unstamped build should
              # admit to being.
              export DAZZLE_BUILD="$(${pkgs.git}/bin/git rev-parse --short HEAD 2>/dev/null || echo dev)"

              # The SDK stays off PATH on purpose: the host adb owns the server,
              # flutter and gradle reach the SDK through ANDROID_HOME instead.
              # Store paths change with the flake lock, so these two keys are
              # rewritten per shell and never committed. Every other key is kept:
              # `flutter build` writes flutter.versionCode into the same file for
              # gradle to read back, and a shell opening mid-build used to
              # truncate it, costing the apk its version.
              if [ -d android ]; then
                props=android/local.properties
                {
                  printf 'sdk.dir=%s\n' ${sdkRoot}
                  printf 'flutter.sdk=%s\n' ${pkgs.flutter}
                  if [ -e "$props" ]; then
                    ${pkgs.gnugrep}/bin/grep -vE '^(sdk\.dir|flutter\.sdk)=' "$props" || true
                  fi
                } > "$props.tmp"
                mv -f "$props.tmp" "$props"
              fi
            '';
          };
        }
      );
    };
}
