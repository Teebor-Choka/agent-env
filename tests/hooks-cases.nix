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
  h = id: event: extra: { inherit id event; script = "hooks/${id}.sh"; enforce = "warn"; } // extra;
  render = hooks: l.renderClaudeHooks { inherit hooks; };
  fails = hooks: !(builtins.tryEval (builtins.deepSeq (render hooks) true)).success;
in
{
  gated = l.renderClaudeHooks byName.gated.hooks;
  expectedGated = builtins.fromJSON (builtins.readFile "${fix}/market/gated-expected-claude.json");
  plainHooks = byName.plain.hooks;
  empty = render [ ];
  multiTool = render [
    (h "a" "tool.before" { tools = [ "file.edit" "shell" ]; })
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
  unknownEventFails = fails [ (h "a" "tool.sideways" { }) ];
  unknownToolFails = fails [ (h "a" "tool.before" { tools = [ "teleport" ]; }) ];
}
