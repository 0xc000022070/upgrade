{
  lib,
  stdenv,
  callPackage,
  rustPlatform,
  lld,
  ghosttyVt ? callPackage ./libghostty-vt.nix { },
}:

rustPlatform.buildRustPackage {
  pname = "upgraded";
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

  # ld.bfd 2.46 rejects the overlapping FDEs in the Zig-built libghostty-vt.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ lld ];

  env = {
    GHOSTTY_VT_LIB_DIR = "${ghosttyVt.dev}/lib";
  }
  // lib.optionalAttrs stdenv.hostPlatform.isLinux {
    RUSTFLAGS = "-C link-arg=-fuse-ld=lld";
  };

  meta = {
    description = "The host side of a Upgrade plugin: one binary, exec'd per call";
    mainProgram = "upgraded";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
