{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.strikedddd;
  format = pkgs.formats.json { };
in
{
  options.services.strikedddd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install strikedddd on this machine and write the configuration it
        reads.

        The engine is not a daemon. The phone execs the binary over an ssh
        connection it already holds, and that process reads one request, writes
        one answer and exits. Enabling this puts the binary on PATH and writes
        /etc/strikedddd/config.json. It starts nothing, and there is no unit to
        enable.

        The one thing that outlives a call is a shell/1 server, started by one: a
        terminal session the phone reaches over UDP in place of ssh or mosh. It
        runs as the account that started it, listens on one port of shellPorts for
        that one tab, and exits when its shell ends or it is stopped. A server no
        phone ever reaches leaves after a minute.

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
      defaultText = lib.literalMD "the `engine` package of the Upgrade flake";
      description = ''
        The engine build to install. Defaults to the engine package of the
        Upgrade flake this module came from, which is built against that flake's
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
        /etc/strikedddd/config.json apply to every account either way.

        nix-darwin has no per-user profile to install into, so this list is
        ignored there and the engine is installed for the whole machine.
      '';
    };

    shellPorts = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            from = lib.mkOption { type = lib.types.port; };
            to = lib.mkOption { type = lib.types.port; };
          };
        }
      );
      default = null;
      example = {
        from = 60001;
        to = 60999;
      };
      description = ''
        The UDP ports a shell/1 server may listen on, one port per running tab.
        Left null, the engine uses 60001-60999, the range mosh uses.

        The engine intersects the ranges of every config file it reads, so a
        home-manager install can narrow this and never widen it.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      internal = true;
      readOnly = true;
      # The key names are the ones the engine deserializes, and it rejects a
      # file carrying any other key.
      default = format.generate "strikedddd-config.json" (
        {
          inherit (cfg) denyCapabilities denyExec;
        }
        // lib.optionalAttrs (cfg.shellPorts != null) { inherit (cfg) shellPorts; }
      );
      description = "The rendered /etc/strikedddd/config.json.";
    };
  };
}
