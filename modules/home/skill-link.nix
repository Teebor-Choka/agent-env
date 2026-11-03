# modules/home/skill-link.nix
# Symlink SKILL.md-containing dirs from source trees flat into a target dir (default ~/.claude/skills)
# and any `extraTargets`, so a tool that expects <target>/<name>/SKILL.md (and does not scan
# recursively) finds them. Typically paired with `home.gitClone` source clones; runs after the `gitClone` activation node.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    mkIf
    escapeShellArg
    concatStringsSep
    ;
  cfg = config.home.skillLink;
in
{
  options.home.skillLink = {
    enable = mkOption {
      type = types.bool;
      default = false;
    };
    target = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.claude/skills";
    };
    sources = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Absolute dirs scanned recursively for SKILL.md (later source wins on name clash).";
    };
    extraTargets = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        More dirs that get the same links as `target` (for example ~/.agents/skills, which Codex,
        OpenCode, and oh-my-pi read). Links into the Nix store, such as those home.agentPlugins
        writes there, are left alone.
      '';
    };
    exclude = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Skill names to skip, because another path delivers them (for example a plugin).";
    };
  };

  config = mkIf cfg.enable {
    home.activation.skillLink = lib.hm.dag.entryAfter [ "gitClone" ] ''
      excl=${escapeShellArg " ${concatStringsSep " " cfg.exclude} "}
      for target in ${concatStringsSep " " (map escapeShellArg ([ cfg.target ] ++ cfg.extraTargets))}; do
        if [ -e "$target/.git" ]; then
          echo "skillLink: ERROR $target is a git checkout — back it up and remove it, then re-run." >&2
          exit 1
        fi
        $DRY_RUN_CMD mkdir -p "$target"
        # Prune only the links this module made; a link into the store belongs to another module.
        $DRY_RUN_CMD find "$target" -maxdepth 1 -type l ! -lname '/nix/store/*' -delete
        for src in ${concatStringsSep " " (map escapeShellArg cfg.sources)}; do
          [ -d "$src" ] || { echo "skillLink: WARNING missing source $src" >&2; continue; }
          ${pkgs.findutils}/bin/find "$src" -name '.*' -prune -o -type f -name SKILL.md -print | while IFS= read -r f; do
            dir=${"$"}{f%/*}; name=${"$"}{dir##*/}; link="$target/$name"
            case "$excl" in *" $name "*) continue ;; esac
            [ -L "$link" ] && echo "skillLink: WARNING '$name' overridden by $dir" >&2
            $DRY_RUN_CMD ln -sfn "$dir" "$link"
          done
        done
      done
    '';
  };
}
