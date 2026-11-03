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
  chat = android.rustPlatform.buildRustPackage {
    pname = "upgrade-chat";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ../../chat;
      fileset = lib.fileset.unions [
        ../../chat/Cargo.toml
        ../../chat/Cargo.lock
        ../../chat/src
        ../../chat/examples
      ];
    };

    cargoLock.lockFile = ../../chat/Cargo.lock;
    cargoBuildFlags = [ "--lib" ];
    doCheck = false;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 target/*/release/libupgrade_chat.so $out/lib/libupgrade_chat.so
      runHook postInstall
    '';
  };
in
runCommand "upgrade-chat-android" { } ''
  install -Dm755 ${chat}/lib/libupgrade_chat.so $out/arm64-v8a/libupgrade_chat.so
''
