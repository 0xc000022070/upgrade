{
  description = "Hotline — local-first personal control plane (Flutter)";

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
            name = "hotline";

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
              # The SDK stays off PATH on purpose: the host adb owns the server,
              # flutter and gradle reach the SDK through ANDROID_HOME instead.
              # Store paths change with the flake lock, so this file is rewritten
              # per shell and never committed.
              if [ -d android ]; then
                cat > android/local.properties <<-PROPS
					sdk.dir=${sdkRoot}
					flutter.sdk=${pkgs.flutter}
				PROPS
              fi
            '';
          };
        }
      );
    };
}
