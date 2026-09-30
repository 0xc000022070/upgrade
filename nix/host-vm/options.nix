{ config, lib, ... }:

{
  options.dazzleHost = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "full";
    };
    sshPort = lib.mkOption { type = lib.types.port; };
    mosh = {
      from = lib.mkOption { type = lib.types.port; };
      to = lib.mkOption {
        type = lib.types.port;
        default = config.dazzleHost.mosh.from + 15;
      };
    };
    engine = lib.mkEnableOption "the Dazzle engine";
    herdr = lib.mkEnableOption "herdr";
    codex = lib.mkEnableOption "the patched codex fixture";
    declaredHooks = lib.mkEnableOption "agent configs linked into the store";
  };
}
