# modules/home/agent-plugins.nix
# Deliver every plugin of one or more skills repos to the agent harnesses from the repos'
# marketplace manifests. The skill dirs stay the single source of truth; a plugin is a thin
# bundle over them (see agent-plugins-lib.nix). opt-in: home.agentPlugins.enable.
#   Claude Code: one closure per plugin, linked at a stable path (~/.claude/plugin-dirs/<name>) and
#                loaded with a repeated `--plugin-dir` by a `claude` shell function that globs that
#                dir at launch, so skills surface namespaced (`plugin:skill`) and a rebuild reaches
#                even a shell that was opened before it.
#   oh-my-pi, OpenCode, Codex: every skill linked under `skillsTarget` (~/.agents/skills).
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
    mkMerge
    concatMap
    concatStringsSep
    mapAttrsToList
    listToAttrs
    mapAttrs'
    nameValuePair
    removePrefix
    unique
    ;
  cfg = config.home.agentPlugins;
  agentLib = import ./agent-plugins-lib.nix { inherit lib; };
  plugins = concatMap (m: agentLib.normalize { inherit (m) src exclude; }) cfg.marketplaces;

  # Skills-mode plugins have no directory of their own: build one that links the skill dirs.
  closure =
    p:
    if p.root != null then
      p.root
    else
      pkgs.runCommand "plugin-${p.name}" { } ''
        mkdir -p $out/.claude-plugin $out/skills
        cp ${
          pkgs.writeText "plugin.json" (
            builtins.toJSON (
              {
                inherit (p) name description;
              }
              // lib.optionalAttrs (p.version != null) { inherit (p) version; }
              // lib.optionalAttrs (p.author != null) { inherit (p) author; }
            )
          )
        } $out/.claude-plugin/plugin.json
        ${concatStringsSep "\n" (mapAttrsToList (n: path: "ln -s ${path} $out/skills/${n}") p.skills)}
      '';

  skillsRel = removePrefix "${config.home.homeDirectory}/" cfg.skillsTarget;
  pluginDirsRel = ".claude/plugin-dirs";
in
{
  options.home.agentPlugins = {
    enable = mkEnableOption "delivering marketplace plugins to the agent harnesses";

    marketplaces = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            src = mkOption {
              type = types.str;
              description = "Store path of a skills repo (a flake input) holding `.claude-plugin/marketplace.json`.";
            };
            exclude = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Plugin names delivered elsewhere (for example by `home.swePlugin`).";
            };
          };
        }
      );
      default = [ ];
    };

    skillsTarget = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.agents/skills";
      description = "Cross-harness skills dir read by oh-my-pi, OpenCode, and Codex.";
    };

    skillNames = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default = unique (concatMap (p: p.skillNames) plugins);
      description = "Read-only: every skill delivered here. Feed to `home.skillLink.exclude`.";
    };

    claudePlugins = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Plugin name to plugin dir (a store path) for Claude Code. Each is linked at
        `~/.claude/plugin-dirs/<name>`; the `claude` function launches with one `--plugin-dir`
        per entry in that dir. Attrsets merge, so a module that wires its own plugin
        (home.swePlugin) adds its dir here.
      '';
    };

    pluginDirs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra `--plugin-dir` values passed verbatim, for a dir that has no stable name. Prefer
        `claudePlugins`: these are baked into the function and need a rebuild and a new shell.
      '';
    };
  };

  config = mkMerge [
    (mkIf (cfg.claudePlugins != { } || cfg.pluginDirs != [ ]) (
      let
        # `null_glob` (zsh) / the -d test (bash) keep an empty plugin-dirs a no-op, not an error.
        fn = nullGlob: ''
          claude() {
            ${lib.optionalString nullGlob "setopt local_options null_glob"}
            local d; local -a a=()
            for d in "$HOME"/${pluginDirsRel}/*; do [ -d "$d" ] && a+=(--plugin-dir "$d"); done
            ${concatStringsSep "\n" (map (d: "a+=(--plugin-dir ${lib.escapeShellArg d})") cfg.pluginDirs)}
            command claude "''${a[@]}" "$@"
          }
        '';
      in
      {
        home.file = mapAttrs' (
          n: path: nameValuePair "${pluginDirsRel}/${n}" { source = path; }
        ) cfg.claudePlugins;
        programs.zsh.initContent = mkIf config.programs.zsh.enable (fn true);
        programs.bash.initExtra = mkIf config.programs.bash.enable (fn false);
      }
    ))

    (mkIf cfg.enable {
      home.agentPlugins.claudePlugins = listToAttrs (
        map (p: nameValuePair p.name (toString (closure p))) plugins
      );

      home.file = listToAttrs (
        concatMap (
          p: mapAttrsToList (n: path: nameValuePair "${skillsRel}/${n}" { source = path; }) p.skills
        ) plugins
      );
    })
  ];
}
