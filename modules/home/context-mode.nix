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

    replaceTriggerBytes = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 16384;
      description = ''
        Size in bytes above which the plugin replaces a tool result with a search hint
        (`CTX_REPLACE_TRIGGER_BYTES`; the plugin's own default is 4096). The plugin has no per-tool or
        per-command exception, so this one threshold is the only way to keep results of a few KB whole,
        such as a file read before an edit. Null leaves the plugin default. A value is written to
        `env` of settings.json, so it takes effect only with `home.contextMode.enable` and
        `home.claudeSettings.enable`. The merge replaces the live `env` as a whole, so declare every env
        key you need in `home.claudeSettings.settings.env`. Setting this back to null does not remove the
        key from the live file: delete it there, or set a value.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The `claude` shell function launches with one --plugin-dir per entry (see home.agentPlugins).
    home.agentPlugins.claudePlugins.context-mode = "${cfg.package}";
    home.claudeSettings.settings.env = lib.mkIf (cfg.replaceTriggerBytes != null) {
      CTX_REPLACE_TRIGGER_BYTES = toString cfg.replaceTriggerBytes;
    };
  };
}
