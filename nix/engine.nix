{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "dazzle-engine";
  version = "0.1.0";

  # Only the crate's own files: the dev shell builds into engine/target, and a
  # plain path source would copy that tree into the store.
  src = lib.fileset.toSource {
    root = ../engine;
    fileset = lib.fileset.unions [
      ../engine/Cargo.toml
      ../engine/Cargo.lock
      ../engine/src
    ];
  };

  cargoLock.lockFile = ../engine/Cargo.lock;

  meta = {
    description = "The host side of a Dazzle plugin: one binary, exec'd per call";
    mainProgram = "dazzle-engine";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
