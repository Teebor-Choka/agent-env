# Cases for the neutral hook manifest renderer (modules/home/agent-plugins-lib.nix), shared by the
# standalone run of tests/hooks-render-suite.sh and the flake check, so both evaluate the same thing.
{ lib, fix }:
let
  l = import ../modules/home/agent-plugins-lib.nix { inherit lib; };
  byName = builtins.listToAttrs (
    map (p: {
      name = p.name;
      value = p;
    }) (l.normalize { src = "${fix}/market"; })
  );
  h =
    id: event: extra:
    {
      inherit id event;
      script = "hooks/${id}.sh";
      enforce = "warn";
    }
    // extra;
  render = hooks: l.renderClaudeHooks { inherit hooks; };
  errs = hooks: l.validateHooks { inherit hooks; };
  fails' = v: !(builtins.tryEval (builtins.deepSeq v true)).success;
  fails = hooks: !(builtins.tryEval (builtins.deepSeq (render hooks) true)).success;
in
{
  gated = l.renderClaudeHooks byName.gated.hooks;
  expectedGated = builtins.fromJSON (builtins.readFile "${fix}/market/gated-expected-claude.json");
  plainHooks = byName.plain.hooks;
  # A plugin with hooks and no skills/ directory must still normalize (home.agentPlugins forces skillNames).
  bareNormalizes = (builtins.tryEval (builtins.deepSeq byName.bare.skillNames true)).success;
  bareSkillNames = (builtins.tryEval byName.bare.skillNames).value;
  empty = render [ ];
  multiTool = render [
    (h "a" "tool.before" {
      tools = [
        "file.edit"
        "shell"
      ];
    })
  ];
  grouped = render [
    (h "a" "tool.before" { tools = [ "shell" ]; })
    (h "b" "tool.before" { tools = [ "file.read" ]; })
    (h "c" "tool.before" { tools = [ "shell" ]; })
  ];
  noMatcher = render [ (h "a" "prompt.submit" { }) ];
  compact = render [ (h "a" "compact" { }) ];
  subagent = render [ (h "a" "subagent.start" { }) ];
  stop = render [ (h "a" "stop" { timeout = 5; }) ];
  # Every neutral alias and the events the fixtures above leave out, mapped to Claude's names.
  aliases = render (
    map (t: h t "tool.before" { tools = [ t ]; }) [
      "shell"
      "file.read"
      "file.edit"
      "agent.spawn"
      "ask.user"
      "message.send"
      "wake.schedule"
    ]
  );
  endAfter = render [
    (h "e" "session.end" { })
    (h "t" "tool.after" { tools = [ "shell" ]; })
  ];
  # Validation: exact messages, so a throw for the wrong reason cannot pass.
  validGated = l.validateHooks byName.gated.hooks;
  errUnknownEvent = errs [ (h "a" "tool.sideways" { }) ];
  errUnknownTool = errs [ (h "a" "tool.before" { tools = [ "teleport" ]; }) ];
  errEmptyTools = errs [ (h "a" "tool.before" { tools = [ ]; }) ];
  errToolsAndMatcher = errs [
    (h "a" "tool.before" {
      tools = [ "shell" ];
      matcher = "Bash";
    })
  ];
  errCompactMatcher = errs [ (h "a" "compact" { matcher = "startup"; }) ];
  errCompactTools = errs [ (h "a" "compact" { tools = [ "shell" ]; }) ];
  errToolsOnPrompt = errs [ (h "a" "prompt.submit" { tools = [ "shell" ]; }) ];
  errEnforce = errs [ (h "a" "stop" { enforce = "blcok"; }) ];
  errNoId = l.validateHooks {
    hooks = [
      {
        event = "stop";
        script = "hooks/x.sh";
        enforce = "warn";
      }
    ];
  };
  errNoEvent = l.validateHooks {
    hooks = [
      {
        id = "a";
        script = "hooks/x.sh";
        enforce = "warn";
      }
    ];
  };
  errNoScript = l.validateHooks {
    hooks = [
      {
        id = "a";
        event = "stop";
        enforce = "warn";
      }
    ];
  };
  errDuplicate = errs [
    (h "a" "stop" { })
    (h "a" "session.end" { })
  ];
  errScriptDotDot = errs [ (h "a" "stop" { script = "../x.sh"; }) ];
  errScriptAbsolute = errs [ (h "a" "stop" { script = "/bin/x.sh"; }) ];
  errScriptQuote = errs [ (h "a" "stop" { script = "x\".sh"; }) ];
  errScriptDollar = errs [ (h "a" "stop" { script = "$(x).sh"; }) ];
  errNoHooksList = l.validateHooks { };
  # The renderer throws on any validation error, and renders the same hook once it is valid.
  invalidFails = fails [ (h "a" "tool.before" { tools = [ ]; }) ];
  validControl = !(fails [ (h "a" "tool.before" { tools = [ "shell" ]; }) ]);

  # A1: the script allowlist. Newline, trailing backslash, empty, space and unicode all fail.
  errScriptNewline = errs [ (h "a" "stop" { script = "hooks/a\n$(cmd)"; }) ];
  errScriptBackslash = errs [ (h "a" "stop" { script = "hooks/a\\"; }) ];
  errScriptEmpty = errs [ (h "a" "stop" { script = ""; }) ];
  errScriptSpace = errs [ (h "a" "stop" { script = "hooks/a b.sh"; }) ];
  errScriptUnicode = errs [ (h "a" "stop" { script = "hooks/é.sh"; }) ];
  validScriptChars = errs [ (h "a" "stop" { script = "hooks/Dir_1/a-b.v2.sh"; }) ];

  # A2: wrong types give one message per field and never throw.
  errHookNotAttrs = errs [ "x" ];
  errIdNum = errs [ ((h "a" "stop" { }) // { id = 5; }) ];
  errEventNum = errs [ ((h "a" "stop" { }) // { event = 5; }) ];
  errScriptNum = errs [ (h "a" "stop" { script = 5; }) ];
  errToolsString = errs [ (h "a" "tool.before" { tools = "shell"; }) ];
  errToolsNonString = errs [ (h "a" "tool.before" { tools = [ 5 ]; }) ];
  errMatcherNum = errs [ (h "a" "stop" { matcher = 5; }) ];
  errEnforceNum = errs [ (h "a" "stop" { enforce = 5; }) ];
  errTimeoutString = errs [ (h "a" "stop" { timeout = "5"; }) ];
  errTimeoutZero = errs [ (h "a" "stop" { timeout = 0; }) ];
  errTimeoutNegative = errs [ (h "a" "stop" { timeout = -1; }) ];
  errTimeoutFloat = errs [ (h "a" "stop" { timeout = 1.5; }) ];
  validTimeout = errs [ (h "a" "stop" { timeout = 5; }) ];

  # A3: a malformed hooks/manifest.json breaks only that plugin's `hooks`.
  badjsonName = byName.badjson.name;
  badjsonSkillNames = byName.badjson.skillNames;
  # (forcing its `hooks` aborts the eval: tryEval cannot catch a JSON parse error, so the suite's
  # standalone mode checks that in its own nix eval.)
  # A4: a missing skills/ is allowed only for a hooks-only plugin.
  hookjsonSkillNames = byName.hookjson.skillNames;
  ghostSkillsFail = fails' byName.ghost.skillNames;
  renamedSkillsFail = fails' byName.renamed.skillNames;

  # A5: the exact message the renderer throws, and grouping.
  invalidMessage = l.invalidManifestMessage (errs [ (h "bad-hook" "tool.sideways" { }) ]);
  mixedMatcher = render [
    (h "a" "tool.before" { matcher = "Bash"; })
    (h "b" "tool.before" { tools = [ "shell" ]; })
  ];
  compactMerge = render [
    (h "a" "session.start" { matcher = "compact"; })
    (h "b" "compact" { })
  ];
  compactMergeReverse = render [
    (h "b" "compact" { })
    (h "a" "session.start" { matcher = "compact"; })
  ];
  # A6: enforce is validated, not rendered: block and warn render identically.
  enforceSame =
    render [ (h "a" "stop" { enforce = "block"; }) ] == render [ (h "a" "stop" { enforce = "warn"; }) ];
}
