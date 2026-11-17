# modules/home/agent-plugins-lib.nix
# Pure helpers: turn a skills repo's `.claude-plugin/marketplace.json` into normalized plugin
# records, so one manifest drives every agent. Two manifest shapes occur:
#   skills mode: `source = "./"` + `skills = [ "./path/to/skill" … ]` (a thin bundle of skill dirs)
#   dir mode:    `source = "./sub/dir"` — the plugin is a directory holding its own `skills/`
{ lib }:
let
  inherit (lib)
    removePrefix
    removeSuffix
    attrNames
    listToAttrs
    nameValuePair
    ;
  rel = p: removeSuffix "/" (removePrefix "./" p);
  join = src: p: if rel p == "" then src else "${src}/${rel p}";
  # The name an agent knows a skill by is its frontmatter `name`, and Codex/OpenCode require the
  # directory they scan to carry it. Fall back to the dir name when the file has none.
  skillName =
    path:
    let
      line = lib.findFirst (l: lib.hasPrefix "name:" l) null (
        lib.splitString "\n" (builtins.readFile "${path}/SKILL.md")
      );
    in
    if line == null then
      baseNameOf path
    else
      lib.removeSuffix "\"" (lib.removePrefix "\"" (lib.trim (lib.removePrefix "name:" line)));
in
{
  # The marketplace Codex and omp read: `.claude-plugin/marketplace.json` over one dir-mode entry per
  # plugin closure (Codex requires every local source inside the marketplace root).
  marketplaceManifest =
    { name, names }:
    {
      inherit name;
      # omp rejects a catalog with no `owner`.
      owner.name = "agent-env";
      plugins = map (n: {
        name = n;
        source = "./${n}";
      }) names;
    };

  # Codex `config.toml` tables: a local marketplace plus an enable per plugin. The files stay read-only
  # (the store); `codex plugin add` then only fills the plugin cache, which never touches the config.
  codexConfig =
    {
      marketplace,
      path,
      names,
    }:
    ''
      [marketplaces.${marketplace}]
      source_type = "local"
      source = "${path}"
    ''
    + lib.concatMapStrings (n: ''

      [plugins."${n}@${marketplace}"]
      enabled = true
    '') names;

  normalize =
    {
      src,
      exclude ? [ ],
    }:
    let
      manifest = builtins.fromJSON (builtins.readFile "${src}/.claude-plugin/marketplace.json");
      mk =
        p:
        let
          isDir = rel p.source != "";
          root = if isDir then join src p.source else null;
          skills =
            if isDir then
              listToAttrs (
                map (n: nameValuePair n "${root}/skills/${n}") (
                  attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir "${root}/skills"))
                )
              )
            else
              listToAttrs (map (s: nameValuePair (skillName (join src s)) (join src s)) (p.skills or [ ]));
        in
        {
          inherit (p) name;
          description = p.description or "";
          version = p.metadata.version or null;
          author = manifest.owner or null;
          inherit root skills;
          skillNames = attrNames skills;
        };
    in
    map mk (builtins.filter (p: !(builtins.elem p.name exclude)) manifest.plugins);
}
