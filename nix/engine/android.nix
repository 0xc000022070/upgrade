{
  lib,
  callPackage,
  pkgsCross,
  runCommand,
}:

# The engine for the Linux the app runs on the phone. ghostty's own build targets the
# machine it runs on, so zig is handed the target rather than a cross toolchain.
let
  ghosttyVt = (callPackage ./libghostty-vt.nix { }).overrideAttrs (old: {
    zigBuildFlags = lib.toList old.zigBuildFlags ++ [ "-Dtarget=aarch64-linux-musl" ];
    dontFixup = true;
  });
  engine = pkgsCross.aarch64-multiplatform-musl.pkgsStatic.callPackage ./package.nix {
    inherit ghosttyVt;
  };
in
runCommand "strikedddd-android" { } ''
  install -Dm755 ${lib.getExe engine} $out/arm64-v8a/libstrikedddd.so
''
