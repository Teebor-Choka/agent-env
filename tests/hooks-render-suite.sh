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
  # <nixpkgs> from NIX_PATH when present, else the nixpkgs flake's path.
  if nix-instantiate --eval -E '<nixpkgs>' >/dev/null 2>&1; then
    lib='import <nixpkgs/lib>'
  else
    lib="import \"$(nix eval --raw nixpkgs#path)/lib\""
  fi
  out=$(nix eval --impure --json --expr \
    "import ./tests/hooks-cases.nix { lib = ($lib); fix = \"$fix\"; }")
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
path_err='hook a: script must be a relative path of [A-Za-z0-9._/-] without ..'
check "script with .." "$(one "$path_err")" "$(get '.errScriptDotDot')"
check "absolute script" "$(one "$path_err")" "$(get '.errScriptAbsolute')"
check "script with a quote" "$(one "$path_err")" "$(get '.errScriptQuote')"
check "script with a dollar" "$(one "$path_err")" "$(get '.errScriptDollar')"
check "manifest without a hooks list" "$(one 'manifest: hooks must be a list')" "$(get '.errNoHooksList')"
check "the renderer throws on an invalid manifest" 'true' "$(get '.invalidFails')"
check "the same hook renders once valid" 'true' "$(get '.validControl')"

check "script with a newline" "$(one "$path_err")" "$(get '.errScriptNewline')"
check "script with a trailing backslash" "$(one "$path_err")" "$(get '.errScriptBackslash')"
check "empty script" "$(one "$path_err")" "$(get '.errScriptEmpty')"
check "script with a space" "$(one "$path_err")" "$(get '.errScriptSpace')"
check "script with unicode" "$(one "$path_err")" "$(get '.errScriptUnicode')"
check "script chars: letters, digits, . _ - /" '[]' "$(get '.validScriptChars')"

check "a hook that is not an attrset" "$(one 'hook #0: must be an attribute set')" "$(get '.errHookNotAttrs')"
check "numeric id" "$(one 'hook #0: id must be a non-empty string')" "$(get '.errIdNum')"
check "numeric event" "$(one 'hook a: event must be a string')" "$(get '.errEventNum')"
check "numeric script" "$(one 'hook a: script must be a string')" "$(get '.errScriptNum')"
check "tools as a string" "$(one 'hook a: tools must be a list of strings')" "$(get '.errToolsString')"
check "tools with a non-string" "$(one 'hook a: tools must be a list of strings')" "$(get '.errToolsNonString')"
check "numeric matcher" "$(one 'hook a: matcher must be a string')" "$(get '.errMatcherNum')"
check "numeric enforce yields one message" "$(one 'hook a: enforce must be block or warn')" "$(get '.errEnforceNum')"
tmo='hook a: timeout must be a positive integer'
check "string timeout" "$(one "$tmo")" "$(get '.errTimeoutString')"
check "zero timeout" "$(one "$tmo")" "$(get '.errTimeoutZero')"
check "negative timeout" "$(one "$tmo")" "$(get '.errTimeoutNegative')"
check "float timeout" "$(one "$tmo")" "$(get '.errTimeoutFloat')"
check "a positive integer timeout is valid" '[]' "$(get '.validTimeout')"

check "a malformed manifest leaves the plugin name usable" '"badjson"' "$(get '.badjsonName')"
check "a malformed manifest leaves skillNames usable" '["z"]' "$(get '.badjsonSkillNames')"
check "hooks/hooks.json alone allows a missing skills/" '[]' "$(get '.hookjsonSkillNames')"
check "a mistyped source (no dir) still errors" 'true' "$(get '.ghostSkillsFail')"
check "a renamed skills/ with no hooks still errors" 'true' "$(get '.renamedSkillsFail')"

check "the exact message the renderer throws" \
  '"invalid hook manifest: hook bad-hook: unknown event \"tool.sideways\""' "$(get '.invalidMessage')"
check "raw matcher Bash and tools [shell] share one group, in manifest order" \
  '[{"matcher":"Bash","cmds":["\"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh\"","\"${CLAUDE_PLUGIN_ROOT}/hooks/b.sh\""]}]' \
  "$(get '[.mixedMatcher.hooks.PreToolUse[] | {matcher, cmds: [.hooks[].command]}]')"
cmp_groups='[.hooks.SessionStart[] | {matcher, ids: [.hooks[].command | capture("hooks/(?<i>[a-z]+)").i]}]'
check "compact merges with a session.start hook matching compact" \
  '[{"matcher":"compact","ids":["a","b"]}]' "$(jq -c "$cmp_groups" <<<"$(get .compactMerge)")"
check "compact merge keeps manifest order when compact is first" \
  '[{"matcher":"compact","ids":["b","a"]}]' "$(jq -c "$cmp_groups" <<<"$(get .compactMergeReverse)")"
check "block and warn render identically (enforce is not rendered)" 'true' "$(get '.enforceSame')"

if [ "$standalone" = 1 ]; then
  err=$(nix eval --impure --json --expr "
    builtins.deepSeq true ((import ./modules/home/agent-plugins-lib.nix { lib = ($lib); }).renderClaudeHooks
      { hooks = [ { id = \"bad-hook\"; event = \"tool.sideways\"; script = \"hooks/x.sh\"; enforce = \"warn\"; } ]; })" 2>&1 >/dev/null || true)
  # -F on the full message: the bare tokens also appear in the echoed --expr source.
  check "the thrown error carries the validation message" '1' \
    "$(grep -cF 'invalid hook manifest: hook bad-hook: unknown event "tool.sideways"' <<<"$err" || true)"
  # Nix cannot catch a JSON parse error, so the plugin is named through an error context.
  err=$(nix eval --impure --json --expr "
    builtins.deepSeq true (builtins.head (builtins.filter (p: p.name == \"badjson\")
      ((import ./modules/home/agent-plugins-lib.nix { lib = ($lib); }).normalize { src = \"$fix/market\"; })) ).hooks" 2>&1 >/dev/null || true)
  check "a malformed manifest fails that plugin's hooks" '1' \
    "$(grep -c 'parse_error' <<<"$err" || true)"
  check "a malformed manifest error names the plugin" '1' \
    "$(grep -cF 'plugin badjson: hooks/manifest.json is not valid JSON' <<<"$err" || true)"
fi
exit $fail
