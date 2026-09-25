{ pkgs }:

let
  android = pkgs.callPackage ./android-sdk.nix { };
  sdkRoot = "${android.androidsdk}/libexec/android-sdk";
  ndkRoot = "${sdkRoot}/ndk/28.2.13676358";
  jdk = pkgs.jdk21;

  ghosttySrc = pkgs.fetchFromGitHub {
    owner = "ghostty-org";
    repo = "ghostty";
    rev = "349f026087d948f8f898dca3231ff91438f83ab8";
    hash = "sha256-0/eonC+DEqnQpkKZP+CkEI9saK90i3/FnMeNmO9NeIw=";
  };

  libghosttyRev = "56a95052776e75816a3ab0c0057c20c850944265";
  libghosttySrc = pkgs.fetchFromGitHub {
    owner = "elias8";
    repo = "libghostty";
    rev = libghosttyRev;
    hash = "sha256-Miw8srT1YJ6DJvX0TFKs/3iDtI+HdMCdRBcjhxjymZU=";
  };
in
pkgs.mkShell {
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

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.sqlite ];

  ANDROID_HOME = sdkRoot;
  ANDROID_SDK_ROOT = sdkRoot;
  ANDROID_NDK_ROOT = ndkRoot;
  ANDROID_NDK_HOME = ndkRoot;
  GHOSTTY_SRC = ghosttySrc;
  LIBGHOSTTY_SRC = libghosttySrc;
  LIBGHOSTTY_REV = libghosttyRev;
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
}
