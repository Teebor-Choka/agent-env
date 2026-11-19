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

  # The neutral hook vocabulary every renderer shares; each renderer maps it to its harness's names.
  neutralEvents = [
    "session.start"
    "session.end"
    "prompt.submit"
    "tool.before"
    "tool.after"
    "subagent.start"
    "stop"
    "compact"
  ];
  neutralTools = [
    "shell"
    "file.read"
    "file.edit"
    "agent.spawn"
    "ask.user"
    "message.send"
    "wake.schedule"
  ];

  # Error strings for a parsed `hooks/manifest.json`, [ ] when valid. Pure, so a renderer throws from it
  # and the flake check asserts the exact messages. `enforce` is validated here but a renderer may only
  # use it where its harness can block. `compact` fixes its own matcher; a raw `matcher` is for the
  # events that take one. The script is spliced into a quoted shell command, hence the character ban.
  validateHooks =
    manifest:
    let
      hooks = manifest.hooks or null;
      toolEvents = [
        "tool.before"
        "tool.after"
      ];
      badScript =
        s:
        lib.hasPrefix "/" s
        || builtins.elem ".." (lib.splitString "/" s)
        || builtins.match ".*[\"$`].*" s != null;
      one =
        i: h:
        let
          label = "hook ${if h ? id then h.id else "#${toString i}"}";
          err = cond: msg: lib.optional cond "${label}: ${msg}";
          event = h.event or null;
          known = event != null && builtins.elem event neutralEvents;
          hasTools = h ? tools;
        in
        lib.optional (!(h ? id)) "${label}: missing id"
        ++ err (event == null) "missing event"
        ++ err (event != null && !known) "unknown event \"${event}\""
        ++ err (!(h ? script)) "missing script"
        ++ err (
          (h ? script) && badScript h.script
        ) "script must be a relative path without .., quote, $ or backtick"
        ++ err (
          !(builtins.elem (h.enforce or null) [
            "block"
            "warn"
          ])
        ) "enforce must be block or warn"
        ++ err (event == "compact" && (hasTools || h ? matcher)) "compact takes no tools or matcher"
        ++ err (
          known && event != "compact" && hasTools && !(builtins.elem event toolEvents)
        ) "tools apply only to tool.before and tool.after"
        ++ err (event != "compact" && hasTools && h ? matcher) "tools and matcher are exclusive"
        ++ err (hasTools && h.tools == [ ]) "tools must not be empty"
        ++ lib.concatMap (t: err (!(builtins.elem t neutralTools)) "unknown tool alias \"${t}\"") (
          if hasTools then h.tools else [ ]
        );
      ids = lib.concatMap (h: lib.optional (h ? id) h.id) hooks;
      dups = lib.filter (id: lib.count (x: x == id) ids > 1) (lib.unique ids);
    in
    if !(builtins.isList hooks) then
      [ "manifest: hooks must be a list" ]
    else
      lib.concatLists (lib.imap0 one hooks) ++ map (id: "duplicate hook id \"${id}\"") dups;
in
{
  inherit validateHooks;

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

  # A plugin's neutral `hooks/manifest.json` -> Claude Code's `hooks.json`. Hooks sharing an event and
  # matcher join one group, in manifest order. The script path is quoted: `claude plugin validate`
  # warns on a bare ${CLAUDE_PLUGIN_ROOT}. `compact` is SessionStart:compact (context after a
  # compaction), not PreCompact. Callers pass a parsed manifest, never null (a plugin without one).
  renderClaudeHooks =
    manifest:
    let
      errors = validateHooks manifest;
      events = {
        "session.start".event = "SessionStart";
        "session.end".event = "SessionEnd";
        "prompt.submit".event = "UserPromptSubmit";
        "tool.before".event = "PreToolUse";
        "tool.after".event = "PostToolUse";
        "subagent.start".event = "SubagentStart";
        "stop".event = "Stop";
        "compact" = {
          event = "SessionStart";
          matcher = "compact";
        };
      };
      tools = {
        "shell" = "Bash";
        "file.read" = "Read";
        "file.edit" = "Edit|Write|MultiEdit";
        "agent.spawn" = "Agent";
        "ask.user" = "AskUserQuestion";
        "message.send" = "SendMessage";
        "wake.schedule" = "ScheduleWakeup";
      };
      resolve =
        h:
        let
          ev = events.${h.event};
        in
        {
          inherit (ev) event;
          matcher =
            if h ? tools then
              lib.concatStringsSep "|" (map (t: tools.${t}) h.tools)
            else
              h.matcher or ev.matcher or null;
          entry = {
            type = "command";
            command = "\"\${CLAUDE_PLUGIN_ROOT}/${h.script}\"";
          }
          // lib.optionalAttrs ((h.timeout or null) != null) { inherit (h) timeout; };
        };
      add =
        acc: r:
        let
          groups = acc.${r.event} or [ ];
          i = lib.lists.findFirstIndex (g: (g.matcher or null) == r.matcher) null groups;
        in
        acc
        // {
          ${r.event} =
            if i == null then
              groups
              ++ [
                (lib.optionalAttrs (r.matcher != null) { inherit (r) matcher; } // { hooks = [ r.entry ]; })
              ]
            else
              lib.imap0 (j: g: if j == i then g // { hooks = g.hooks ++ [ r.entry ]; } else g) groups;
        };
    in
    if errors != [ ] then
      throw "invalid hook manifest: ${lib.concatStringsSep "; " errors}"
    else
      {
        hooks = builtins.foldl' add { } (map resolve manifest.hooks);
      };

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
          # The neutral manifest, parsed; null when the plugin ships none (or has no dir of its own).
          hooks =
            if root != null && builtins.pathExists "${root}/hooks/manifest.json" then
              builtins.fromJSON (builtins.readFile "${root}/hooks/manifest.json")
            else
              null;
          skillNames = attrNames skills;
        };
    in
    map mk (builtins.filter (p: !(builtins.elem p.name exclude)) manifest.plugins);
}
