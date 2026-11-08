# modules/t3-connect/delegator.nix
# homeModules.t3-connect-delegator: the delegator's side of the t3-connect layer. The delegator is the
# user's own T3 server (the Mac app's). It installs `t3-link-vm` and `t3-unlink-vm`, which link a
# sandbox to it and forget one. The `t3` CLI must match the delegator's version; pass the matching package.
# `reaper` (off by default, macOS) runs `t3-run-vm --reap-only` on a timer so a link whose wrapper died is
# unlinked without a manual step. See docs/decisions/t3-connect-layer.md.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.t3Connect.delegator;
  reaper = cfg.reaper;
  runVm = import ./run-vm.nix {
    inherit pkgs;
    t3 = cfg.package;
  };
in
{
  options.t3Connect.delegator = {
    enable = lib.mkEnableOption "the t3-link-vm helper for linking sandboxes to this machine's T3 server";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.t3-server;
      defaultText = lib.literalExpression "pkgs.t3-server";
      description = ''
        The `t3` CLI. It writes into the delegator's database, so it must be the delegator's version.
        `pkgs.t3-server` comes from this flake's `overlays.default`, which the consumer applies.
      '';
    };
    reaper = {
      enable = lib.mkEnableOption "a launchd agent that unlinks entries of guests whose t3-run-vm wrapper died";
      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Seconds between runs; the agent also runs at login.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        description = "ssh name of the guests' host, as for `t3-run-vm --host`.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !reaper.enable || pkgs.stdenv.isDarwin;
        message = "t3Connect.delegator.reaper is a launchd agent and needs macOS.";
      }
    ];

    launchd.agents.t3-run-vm-reap = lib.mkIf reaper.enable {
      enable = true;
      config = {
        ProgramArguments = [
          "${runVm}/bin/t3-run-vm"
          "--reap-only"
          "--host"
          reaper.host
        ];
        RunAtLoad = true;
        StartInterval = reaper.interval;
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/t3-run-vm-reap.log";
      };
    };

    home.packages = [
      (import ./link-vm.nix {
        inherit pkgs;
        t3 = cfg.package;
      })
      (import ./unlink-vm.nix {
        inherit pkgs;
        t3 = cfg.package;
      })
    ];
  };
}
