{ callPackage }:

let
  src = callPackage ../ghostty-src.nix { };
in
(callPackage "${src}/nix/libghostty-vt.nix" {
  revision = builtins.substring 0 7 src.rev;
  optimize = "ReleaseFast";
}).overrideAttrs
  (old: {
    # Some zig 0.16 builds emit a compiler_rt.o lld rejects; Rust's
    # compiler_builtins carries the same intrinsics.
    postInstall = (old.postInstall or "") + ''
      for output in $outputs; do
        find "''${!output}" -name 'libghostty-vt.a' -exec ar d {} compiler_rt.o \;
      done
    '';
  })
