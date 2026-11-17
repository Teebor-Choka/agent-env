# modules/home/agent-plugins.nix
# Deliver every plugin of one or more skills repos to the agent harnesses from the repos'
# marketplace manifests. The skill dirs stay the single source of truth; a plugin is a thin
# bundle over them (see agent-plugins-lib.nix). opt-in: home.agentPlugins.enable.
#   Claude Code: one closure per plugin, linked at a stable path (~/.claude/plugin-dirs/<name>) and
#                loaded with a repeated `--plugin-dir` by a `claude` shell function that globs that
#                dir at launch, so skills surface namespaced (`plugin:skill`) and a rebuild reaches
#                even a shell that was opened before it.
#   Codex, oh-my-pi, pi (`native = true`): the same closures as plugins of one generated marketplace
#                (Codex, omp) or as pi packages, so each harness namespaces them like Claude does.
#   OpenCode (and every harness while `native = false`): the skills as raw dirs, since OpenCode has no
#                skill-bearing plugin form. Codex, omp and pi also scan ~/.agents/skills, so with
#                `native = true` the raw copies go to ~/.config/opencode/skills instead, or each
#                plugin skill would list twice.
# Scope: Claude Code, pi, omp, Codex and OpenCode. See README.md.
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
    attrNames
    attrValues
    mapAttrs
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

  rel = removePrefix "${config.home.homeDirectory}/";
  skillsRel = rel cfg.pluginSkillsTarget;
  pluginDirsRel = ".claude/plugin-dirs";

  mkName = "agent-env";
  pluginNames = attrNames cfg.claudePlugins;

  # Every closure as a dir-mode plugin of one marketplace. Copied (not linked): Codex wants each local
  # source inside the marketplace root. A closure with no Claude manifest gets a minimal one, and every
  # plugin gets the Codex manifest beside it (same JSON; Codex reads `.codex-plugin/plugin.json`).
  marketplace = pkgs.runCommand "agent-env-plugins" { } ''
    mkdir -p $out/.claude-plugin
    cp ${
      pkgs.writeText "marketplace.json" (
        builtins.toJSON (
          agentLib.marketplaceManifest {
            name = mkName;
            names = pluginNames;
          }
        )
      )
    } $out/.claude-plugin/marketplace.json
    ${concatStringsSep "\n" (
      mapAttrsToList (n: path: ''
        cp -rL ${path} $out/${n}
        chmod -R u+w $out/${n}
        mkdir -p $out/${n}/.claude-plugin $out/${n}/.codex-plugin
        [ -e $out/${n}/.claude-plugin/plugin.json ] || echo '{"name":"${n}"}' > $out/${n}/.claude-plugin/plugin.json
        [ -e $out/${n}/.codex-plugin/plugin.json ] || cp $out/${n}/.claude-plugin/plugin.json $out/${n}/.codex-plugin/plugin.json
      '') cfg.claudePlugins
    )}
  '';

  nativePath = lib.makeBinPath [
    pkgs.jq
    pkgs.coreutils
  ];
  piSettings = "$HOME/.pi/agent/settings.json";
  piState = "$HOME/.pi/agent/.agent-env-packages";
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

    native = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Deliver the plugins natively to Codex (marketplace + `codex plugin add`), oh-my-pi
        (marketplace + `omp plugin install`) and pi (a `packages` entry per plugin in
        ~/.pi/agent/settings.json). Each step runs only when that harness is on PATH. Codex's
        `config.toml` then gets the marketplace and enable tables as `home.file` text, which merges
        with `home.swePlugin`'s Codex hook; do not set `codex` as a plugin target without owning that
        file. Raw plugin skills leave ~/.agents/skills for `pluginSkillsTarget` (see there).
      '';
    };

    pluginSkillsTarget = mkOption {
      type = types.str;
      default =
        if cfg.native then "${config.home.homeDirectory}/.config/opencode/skills" else cfg.skillsTarget;
      defaultText = "~/.config/opencode/skills when `native`, else `skillsTarget`";
      description = ''
        Where plugin skills are linked raw, for harnesses with no native plugin form (OpenCode).
        Not ~/.agents/skills once `native` is on, because Codex, omp and pi read that dir too.
      '';
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

    (mkIf (cfg.enable && cfg.native) {
      home.file.".codex/config.toml".text = agentLib.codexConfig {
        marketplace = mkName;
        path = toString marketplace;
        names = pluginNames;
      };

      # Each step is a no-op when its harness is absent. Remove-then-add so a rebuilt store path with
      # an unchanged plugin version still refreshes the harness's cache. pi settings are CLI-owned, so
      # merge: drop the store paths this module wrote last time (kept in a state file), add the new.
      home.activation.agentPluginsNative = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${nativePath}:$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$PATH"
        if command -v codex >/dev/null 2>&1; then
          # A rebuilt store path with an unchanged plugin version would keep the old cached copy.
          $DRY_RUN_CMD rm -rf "$HOME/.codex/plugins/cache/${mkName}"
          ${concatStringsSep "\n" (
            map (n: ''
              # `add` installs, then exits 1: it cannot rewrite the read-only config.toml. Trust the list.
              $DRY_RUN_CMD codex plugin add ${n}@${mkName} >/dev/null 2>&1 || true
              codex plugin list 2>/dev/null | grep -q '^${n}@${mkName} .*installed' ||
                echo "agentPlugins: WARNING codex plugin ${n} not installed" >&2
            '') pluginNames
          )}
        fi
        if command -v omp >/dev/null 2>&1; then
          $DRY_RUN_CMD omp plugin marketplace remove ${mkName} >/dev/null 2>&1 || true
          $DRY_RUN_CMD omp plugin marketplace add ${marketplace} || echo "agentPlugins: WARNING omp marketplace add failed" >&2
          ${concatStringsSep "\n" (
            map (
              n:
              "$DRY_RUN_CMD omp plugin install --force ${n}@${mkName} || echo \"agentPlugins: WARNING omp install ${n} failed\" >&2"
            ) pluginNames
          )}
        fi
        if command -v pi >/dev/null 2>&1; then
          $DRY_RUN_CMD mkdir -p "$(dirname "${piSettings}")"
          [ -s "${piSettings}" ] || [ -n "$DRY_RUN_CMD" ] || echo '{}' > "${piSettings}"
          old=$(cat "${piState}" 2>/dev/null || true)
          new='${builtins.toJSON (attrValues (mapAttrs (_: toString) cfg.claudePlugins))}'
          tmp=$(mktemp)
          jq --argjson new "$new" --arg old "$old" \
            '.packages = (((.packages // []) - ($old | split("\n"))) + $new | unique)' \
            "${piSettings}" > "$tmp" && $DRY_RUN_CMD mv "$tmp" "${piSettings}"
          [ -n "$DRY_RUN_CMD" ] || printf '%s' "$new" | jq -r '.[]' > "${piState}"
        fi
      '';
    })

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
