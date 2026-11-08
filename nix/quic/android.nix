{
  lib,
  config,
  path,
  stdenv,
  runCommand,
}:

let
  # minSdk's API level: against nixpkgs' default, std binds getrandom to a
  # libc symbol Android 7 and 8 lack, and the library would not load there.
  android = import path {
    inherit config;
    localSystem = stdenv.buildPlatform;
    crossSystem = lib.systems.examples.aarch64-android-prebuilt // {
      androidSdkVersion = "24";
    };
  };
  quic = android.rustPlatform.buildRustPackage {
    pname = "upgrade-quic";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ../../quic;
      fileset = lib.fileset.unions [
        ../../quic/Cargo.toml
        ../../quic/Cargo.lock
        ../../quic/src
      ];
    };

    cargoLock.lockFile = ../../quic/Cargo.lock;
    cargoBuildFlags = [ "--lib" ];
    doCheck = false;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 target/*/release/libupgrade_quic.so $out/lib/libupgrade_quic.so
      runHook postInstall
    '';
  };
in
runCommand "upgrade-quic-android" { } ''
  install -Dm755 ${quic}/lib/libupgrade_quic.so $out/arm64-v8a/libupgrade_quic.so
''
