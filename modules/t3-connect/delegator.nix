# modules/t3-connect/delegator.nix
# homeModules.t3-connect-delegator: the delegator's side of the t3-connect layer. The delegator is the
# user's own T3 server (the Mac app's). It installs `t3-link-vm` and `t3-unlink-vm`, which link a
# sandbox to it and forget one. The `t3` CLI must match the delegator's version; pass the matching package. See
# docs/decisions/t3-connect-layer.md.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.t3Connect.delegator;
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
  };

  config = lib.mkIf cfg.enable {
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
