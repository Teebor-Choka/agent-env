# modules/home/claude-settings.nix
# Declare Claude Code's settings.json and merge it into the live file on activation. Claude writes
# settings.json itself (/model, /plugin), so it is not a read-only store link: claude-settings-merge.sh
# lets declared top-level keys win and keeps every other key. opt-in: home.claudeSettings.enable.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    ;
  cfg = config.home.claudeSettings;
  agentLib = import ./agent-plugins-lib.nix { inherit lib; };
  json = pkgs.formats.json { };

  merge = pkgs.writeTextFile {
    name = "claude-settings-merge";
    executable = true;
    destination = "/bin/claude-settings-merge";
    text = builtins.readFile ./claude-settings-merge.sh;
  };

  # Each plugin's neutral hook manifest as Claude hook groups. ${CLAUDE_PLUGIN_ROOT} is only set for a
  # plugin's own hooks.json, so a hook in settings.json points at the stable plugin-dirs link instead.
  plugins = lib.concatMap (
    m: agentLib.normalize { inherit (m) src exclude; }
  ) config.home.agentPlugins.marketplaces;
  pluginHooks =
    p:
    lib.mapAttrs (
      _: groups:
      map (
        g:
        g
        // {
          hooks = map (
            h:
            h
            // {
              command =
                builtins.replaceStrings [ "\${CLAUDE_PLUGIN_ROOT}" ] [ "$HOME/.claude/plugin-dirs/${p.name}" ]
                  h.command;
            }
          ) g.hooks;
        }
      ) groups
    ) (agentLib.renderClaudeHooks p.hooks).hooks;
  renderedHooks = lib.zipAttrsWith (_: lib.concatLists) (
    map pluginHooks (lib.filter (p: p.hooks != null) plugins)
  );
in
{
  options.home.claudeSettings = {
    enable = mkEnableOption "merging declared settings into ~/.claude/settings.json on activation";

    settings = mkOption {
      type = json.type;
      default = { };
      description = ''
        Declared top-level settings.json keys. On activation each replaces the live value of the same
        key; keys not declared here are left as Claude wrote them. Values land in the world-readable
        store, so keep secrets out.
      '';
    };

    hooksFromPlugins = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also render the `hooks` of every `home.agentPlugins` plugin into settings.json, merged by event.
        Off by default: a plugin loaded with `--plugin-dir` already fires its own hooks.json, so
        rendering them here as well would run each hook twice. Turn it on only when the plugins are not
        loaded as plugins.
      '';
    };

    target = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.claude/settings.json";
      description = "The settings file to merge into.";
    };
  };

  config = mkIf cfg.enable {
    home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${
        lib.makeBinPath [
          pkgs.jq
          pkgs.coreutils
          pkgs.diffutils
        ]
      }:$PATH"
      $DRY_RUN_CMD ${pkgs.bash}/bin/bash ${merge}/bin/claude-settings-merge ${
        lib.escapeShellArgs (
          [
            "--declared"
            (json.generate "claude-settings.json" cfg.settings)
          ]
          ++ lib.optionals cfg.hooksFromPlugins [
            "--hooks"
            (json.generate "claude-hooks.json" renderedHooks)
          ]
          ++ [ cfg.target ]
        )
      }
    '';
  };
}
