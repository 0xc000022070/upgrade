{ callPackage }:

let
  src = callPackage ../ghostty-src.nix { };
in
callPackage "${src}/nix/libghostty-vt.nix" {
  revision = builtins.substring 0 7 src.rev;
  optimize = "ReleaseFast";
}
