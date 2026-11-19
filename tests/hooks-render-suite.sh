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
check "a hooks-only plugin (no skills/ dir) normalizes" 'true' "$(get '.bareNormalizes')"
check "a hooks-only plugin has no skills" '[]' "$(get '.bareSkillNames')"
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
check "every neutral tool alias maps to its Claude tool" \
  '["Bash","Read","Edit|Write|MultiEdit","Agent","AskUserQuestion","SendMessage","ScheduleWakeup"]' \
  "$(get '[.aliases.hooks.PreToolUse[].matcher]')"
check "session.end and tool.after map to SessionEnd and PostToolUse" \
  '["PostToolUse","SessionEnd"]' "$(get '.endAfter.hooks | keys')"

# --- validation: exact messages (a throw for another reason must not pass) ---
one() { jq -nc --arg m "$1" '[$m]'; }
check "a valid manifest has no errors" '[]' "$(get '.validGated')"
check "unknown event" "$(one 'hook a: unknown event "tool.sideways"')" "$(get '.errUnknownEvent')"
check "unknown tool alias" "$(one 'hook a: unknown tool alias "teleport"')" "$(get '.errUnknownTool')"
check "empty tools (would match every tool)" "$(one 'hook a: tools must not be empty')" "$(get '.errEmptyTools')"
check "tools and matcher are exclusive" "$(one 'hook a: tools and matcher are exclusive')" "$(get '.errToolsAndMatcher')"
check "compact rejects a matcher" "$(one 'hook a: compact takes no tools or matcher')" "$(get '.errCompactMatcher')"
check "compact rejects tools" "$(one 'hook a: compact takes no tools or matcher')" "$(get '.errCompactTools')"
check "tools only on tool events" "$(one 'hook a: tools apply only to tool.before and tool.after')" "$(get '.errToolsOnPrompt')"
check "enforce is block or warn" "$(one 'hook a: enforce must be block or warn')" "$(get '.errEnforce')"
check "missing id is labelled by position" "$(one 'hook #0: missing id')" "$(get '.errNoId')"
check "missing event" "$(one 'hook a: missing event')" "$(get '.errNoEvent')"
check "missing script" "$(one 'hook a: missing script')" "$(get '.errNoScript')"
check "duplicate id" "$(one 'duplicate hook id "a"')" "$(get '.errDuplicate')"
path_err='hook a: script must be a relative path without .., quote, $ or backtick'
check "script with .." "$(one "$path_err")" "$(get '.errScriptDotDot')"
check "absolute script" "$(one "$path_err")" "$(get '.errScriptAbsolute')"
check "script with a quote" "$(one "$path_err")" "$(get '.errScriptQuote')"
check "script with a dollar" "$(one "$path_err")" "$(get '.errScriptDollar')"
check "manifest without a hooks list" "$(one 'manifest: hooks must be a list')" "$(get '.errNoHooksList')"
check "the renderer throws on an invalid manifest" 'true' "$(get '.invalidFails')"
check "the same hook renders once valid" 'true' "$(get '.validControl')"

if [ "$standalone" = 1 ]; then
  err=$(nix eval --impure --json --expr "
    builtins.deepSeq true ((import ./modules/home/agent-plugins-lib.nix { lib = import <nixpkgs/lib>; }).renderClaudeHooks
      { hooks = [ { id = \"bad-hook\"; event = \"tool.sideways\"; script = \"hooks/x.sh\"; enforce = \"warn\"; } ]; })" 2>&1 >/dev/null || true)
  # -F on the full message: the bare tokens also appear in the echoed --expr source.
  check "the thrown error carries the validation message" '1' \
    "$(grep -cF 'invalid hook manifest: hook bad-hook: unknown event "tool.sideways"' <<<"$err" || true)"
fi
exit $fail
