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
  fails = hooks: !(builtins.tryEval (builtins.deepSeq (render hooks) true)).success;
in
{
  gated = l.renderClaudeHooks byName.gated.hooks;
  expectedGated = builtins.fromJSON (builtins.readFile "${fix}/market/gated-expected-claude.json");
  plainHooks = byName.plain.hooks;
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
}
