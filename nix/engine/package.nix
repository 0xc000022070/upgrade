{
  lib,
  callPackage,
  rustPlatform,
}:

let
  ghosttyVt = callPackage ./libghostty-vt.nix { };
in
rustPlatform.buildRustPackage {
  pname = "dazzle-engine";
  version = "0.1.0";

  # Only the crate's own files: the dev shell builds into engine/target, and a
  # plain path source would copy that tree into the store.
  src = lib.fileset.toSource {
    root = ../../engine;
    fileset = lib.fileset.unions [
      ../../engine/Cargo.toml
      ../../engine/Cargo.lock
      ../../engine/build.rs
      ../../engine/src
    ];
  };

  cargoLock.lockFile = ../../engine/Cargo.lock;

  env.GHOSTTY_VT_LIB_DIR = "${ghosttyVt.dev}/lib";

  meta = {
    description = "The host side of a Dazzle plugin: one binary, exec'd per call";
    mainProgram = "dazzle-engine";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
