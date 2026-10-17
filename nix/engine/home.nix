{
  config,
  lib,
  ...
}:

let
  cfg = config.services.strikedddd;
in
{
  imports = [ ./options.nix ];

  # No unit here either, user or system: the engine is exec'd per call over the
  # ssh connection the phone already holds, and that process exits.
  config = lib.mkIf cfg.enable {
    home.packages = [
      (lib.warnIf (cfg.users != [ ])
        "services.strikedddd.users has no effect under home-manager; this configuration is one account already"
        cfg.package
      )
    ];

    # The engine reads every config file it finds and unions their deny lists, so
    # what this writes can only add to the ceiling the machine's owner set in
    # /etc. A home-manager install cannot lower it, which is what makes installing
    # the engine as a user safe on a machine somebody else administers.
    #
    # One path serves both platforms: darwin also looks under Application Support,
    # but the XDG candidate is tried everywhere, and this is the directory
    # home-manager owns on either.
    xdg.configFile."strikedddd/config.json".source = cfg.configFile;
  };
}
