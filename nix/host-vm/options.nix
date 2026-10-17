{ config, lib, ... }:

{
  options.strikedHost = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "full";
    };
    sshPort = lib.mkOption { type = lib.types.port; };
    mosh = {
      from = lib.mkOption { type = lib.types.port; };
      to = lib.mkOption {
        type = lib.types.port;
        default = config.strikedHost.mosh.from + 15;
      };
    };
    engine = lib.mkEnableOption "strikedddd";
    herdr = lib.mkEnableOption "herdr";
    codex = lib.mkEnableOption "codex against a local mock of the OpenAI backend";
    declaredHooks = lib.mkEnableOption "agent configs linked into the store";
  };
}
