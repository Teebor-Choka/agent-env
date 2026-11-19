#!/usr/bin/env bash
# Unit test for the neutral hook manifest in modules/home/agent-plugins-lib.nix: a plugin's
# hooks/manifest.json -> the Claude Code hooks.json. jq comparisons over tests/hooks-cases.nix.
#   hooks-render-suite.sh                  one pure `nix eval` (no VM); run anywhere
#   hooks-render-suite.sh <json> <fixdir>  cases already evaluated (the flake check, in the sandbox)
set -euo pipefail
fail=0
check() { # label want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

standalone=0
if [ $# -eq 2 ]; then
  out=$(cat "$1")
else
  standalone=1
  cd "$(dirname "$0")/.."
  fix="$PWD/tests/fixtures/hooks"
  out=$(nix eval --impure --json --expr \
    "import ./tests/hooks-cases.nix { lib = import <nixpkgs/lib>; fix = \"$fix\"; }")
fi
get() { jq -c "$1" <<<"$out"; }

check "swe-workflows-shaped manifest renders the Claude hooks.json" \
  "$(jq -cS . <<<"$(get .expectedGated)")" "$(jq -cS . <<<"$(get .gated)")"
check "a plugin without hooks/manifest.json has no hooks" 'null' "$(get '.plainHooks')"
check "no hooks renders an empty event map" '{"hooks":{}}' "$(get '.empty')"
check "tool aliases join into one matcher, in listed order" '"Edit|Write|MultiEdit|Bash"' \
  "$(get '.multiTool.hooks.PreToolUse[0].matcher')"
check "same event and matcher share one group, in manifest order" \
  '[{"matcher":"Bash","n":2},{"matcher":"Read","n":1}]' \
  "$(get '[.grouped.hooks.PreToolUse[] | {matcher, n: (.hooks | length)}]')"
check "grouped commands keep manifest order" \
  '["\"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh\"","\"${CLAUDE_PLUGIN_ROOT}/hooks/c.sh\""]' \
  "$(get '[.grouped.hooks.PreToolUse[0].hooks[].command]')"
check "an event with no tools or matcher has no matcher key" 'false' \
  "$(get '.noMatcher.hooks.UserPromptSubmit[0] | has("matcher")')"
check "compact is SessionStart with matcher compact" '"compact"' \
  "$(get '.compact.hooks.SessionStart[0].matcher')"
check "subagent.start is SubagentStart" 'true' "$(get '.subagent.hooks | has("SubagentStart")')"
check "timeout carries through on stop" '5' "$(get '.stop.hooks.Stop[0].hooks[0].timeout')"
check "an unknown event is an error" 'true' "$(get '.unknownEventFails')"
check "an unknown tool alias is an error" 'true' "$(get '.unknownToolFails')"

if [ "$standalone" = 1 ]; then
  err=$(nix eval --impure --json --expr "
    builtins.deepSeq 1 ((import ./modules/home/agent-plugins-lib.nix { lib = import <nixpkgs/lib>; }).renderClaudeHooks
      { hooks = [ { id = \"bad-hook\"; event = \"tool.sideways\"; script = \"hooks/x.sh\"; enforce = \"warn\"; } ]; })" 2>&1 >/dev/null || true)
  check "the error names the hook id" '1' "$(grep -c 'bad-hook' <<<"$err" || true)"
  check "the error names the bad event" '1' "$(grep -c 'tool.sideways' <<<"$err" || true)"
fi
exit $fail
