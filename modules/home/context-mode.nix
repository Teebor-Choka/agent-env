# modules/home/context-mode.nix
# Deliver the context-mode plugin (output-limiting hooks + ctx_* MCP tools) to Claude Code, from the
# pinned release bundle in modules/context-mode.nix. opt-in: home.contextMode.enable.
# Claude only: the other harnesses are not wired here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home.contextMode;
in
{
  options.home.contextMode = {
    enable = lib.mkEnableOption "the context-mode plugin for Claude Code (hooks that route large output to a local sandbox, plus ctx_* tools)";

    package = lib.mkOption {
      type = lib.types.package;
      default = import ../context-mode.nix { inherit pkgs; };
      defaultText = lib.literalExpression "pinned release bundle of context-mode (modules/context-mode.nix)";
      description = ''
        The plugin dir: `.claude-plugin/plugin.json`, `hooks/` and `skills/`, with `node` in every
        command rewritten to the store path.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The `claude` shell function launches with one --plugin-dir per entry (see home.agentPlugins).
    home.agentPlugins.claudePlugins.context-mode = "${cfg.package}";
  };
}
