# modules/home/claude-statusline.nix
# Declare Claude Code's statusLine: cost, context size, context-mode and headroom savings.
# opt-in: home.claudeStatusline.enable. Merged into settings.json by home.claudeSettings (enabled here).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home.claudeStatusline;
in
{
  options.home.claudeStatusline = {
    enable = lib.mkEnableOption "the Claude Code statusline with context-mode and headroom savings";

    package = lib.mkOption {
      type = lib.types.package;
      default = import ../claude-statusline.nix { inherit pkgs; };
      description = "The package providing bin/claude-statusline.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.claudeSettings.enable = lib.mkDefault true;
    home.claudeSettings.settings.statusLine = {
      type = "command";
      command = "${cfg.package}/bin/claude-statusline";
    };
  };
}
