{
  config,
  lib,
  ...
}:

let
  cfg = config.services.upgrade-engine;
in
{
  imports = [ ./options.nix ];

  # No launchd daemon and no launchd agent, for the same reason the NixOS module
  # has no unit: the engine is exec'd per call and exits.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (lib.warnIf (cfg.users != [ ])
        "services.upgrade-engine.users has no effect on darwin; the engine is installed for the whole machine"
        cfg.package
      )
    ];

    # nix-darwin's etc activation will not clobber a file it did not write — that
    # is what knownSha256Hashes exists for. Nothing should be in the way of a fresh
    # path under a fresh directory, but a Mac carrying a hand-written config here
    # already is the case that fails, and it fails at activation rather than eval.
    environment.etc."upgrade-engine/config.json".source = cfg.configFile;
  };
}
