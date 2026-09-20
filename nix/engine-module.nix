{
  config,
  lib,
  ...
}:

let
  cfg = config.services.dazzle-engine;
in
{
  imports = [ ./engine-options.nix ];

  # There is deliberately no unit here, user or system. The engine is exec'd per
  # call over the ssh connection the phone already holds, so there is nothing to
  # keep alive between calls.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mkIf (cfg.users == [ ]) [ cfg.package ];

    users.users = lib.genAttrs cfg.users (_: {
      packages = [ cfg.package ];
    });

    # A symlink to a store file, which is world-readable: the ceiling is
    # something every account the engine may run as has to be able to read.
    environment.etc."dazzle-engine/config.json".source = cfg.configFile;
  };
}
