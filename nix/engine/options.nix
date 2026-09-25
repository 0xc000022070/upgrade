{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.dazzle-engine;
  format = pkgs.formats.json { };
in
{
  options.services.dazzle-engine = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install the Dazzle engine on this machine and write the configuration it
        reads.

        The engine is not a daemon. Nothing is resident and nothing listens: the
        phone execs the binary over an ssh connection it already holds, and that
        process reads one request, writes one answer and exits. Enabling this
        puts the binary on PATH and writes /etc/dazzle-engine/config.json. It
        starts nothing, and there is no unit to enable.

        The engine is installed here because the owner of this machine declared
        it. The app never puts it there, and on a machine where this is off, a
        plugin asking for a host service is told the capability is missing.

        Schedules ask for one thing more, and only on Linux: login linger, as
        users.users.<name>.linger, or loginctl enable-linger for an account this
        configuration does not own. Without it systemd stops the account's own
        manager at logout, so a timer would run only while somebody is logged in,
        which is the one time an unattended run is not wanted. The engine reports
        the host unsupported for schedules rather than installing a timer it knows
        will not fire; every other service works either way. Whether an account may
        run things while nobody is logged in belongs to whoever administers the
        machine, so enabling the engine does not grant it.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      defaultText = lib.literalMD "the `engine` package of the Dazzle flake";
      description = ''
        The engine build to install. Defaults to the engine package of the
        Dazzle flake this module came from, which is built against that flake's
        nixpkgs rather than this machine's.
      '';
    };

    denyCapabilities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "git/1"
        "fs/1.write"
      ];
      description = ''
        Capabilities this machine refuses. An entry names either a whole
        service, as in "git/1", or one op of one service, as in "fs/1.read".

        This list is the ceiling the owner of this machine sets. A plugin
        declares the capabilities it wants in its manifest and the phone grants
        them; what the engine actually runs is the intersection of the two, and
        where they disagree the deny wins. A capability named here is refused
        whatever the manifest asked for and whatever the phone granted.
      '';
    };

    denyExec = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "sudo"
        "rm"
      ];
      description = ''
        Programs that run/1 will not start. An entry is matched against the
        program as the call wrote it and against its basename, so "rm" also
        denies "/run/current-system/sw/bin/rm".

        Like denyCapabilities, this wins over anything the phone granted.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "dev" ];
      description = ''
        The accounts that get the binary. Left empty, the engine goes into
        environment.systemPackages and every account on the machine can run it.
        Naming accounts puts it in only those users' profiles instead.

        This only decides who has the binary on PATH. The deny lists in
        /etc/dazzle-engine/config.json apply to every account either way.

        nix-darwin has no per-user profile to install into, so this list is
        ignored there and the engine is installed for the whole machine.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      readOnly = true;
      # The key names are the ones the engine deserializes, and it rejects a
      # file carrying any other key.
      default = format.generate "dazzle-engine-config.json" {
        inherit (cfg) denyCapabilities denyExec;
      };
      description = "The rendered /etc/dazzle-engine/config.json.";
    };
  };
}
