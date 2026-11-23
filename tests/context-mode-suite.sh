#!/usr/bin/env bash
# Regression test for the packaged context-mode plugin (modules/context-mode.nix): a Claude Code plugin
# dir whose hook and MCP commands must call the pinned store node, never a bare `node` that the harness
# PATH may lack. Runs the real PreToolUse hook on a large file and the real MCP server's tools/list.
# Runs in `nix flake check` (checks.<system>.context-mode);
# usage: context-mode-suite.sh <plugin dir> <node binary>.
set -u

plugin="${1:?usage: context-mode-suite.sh <plugin dir> <node binary>}"
node="${2:?usage: context-mode-suite.sh <plugin dir> <node binary>}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/context-mode.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir "$HOME"
fail=0

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1: expected '$2', got '$3'"; fail=1; fi
}

for f in .claude-plugin/plugin.json hooks/claude-code.json server.mjs hook.mjs; do
  [ -f "$plugin/$f" ] && r=present || r=missing
  assert_eq "$f is in the plugin dir" present "$r"
done

# Every command the harness will run starts with the store node.
cmds="$(jq -r '.. | .command? | strings' "$plugin/hooks/claude-code.json" "$plugin/.claude-plugin/plugin.json")"
assert_eq "hook and MCP commands are present" yes "$([ -n "$cmds" ] && echo yes || echo no)"
bare="$(printf '%s\n' "$cmds" | grep -vc "^$node\( \|\$\)")"
assert_eq "no command calls a node other than the pinned one" 0 "$bare"

# The PreToolUse hook denies a Read over the one-read limit and names the sandbox tool.
big="$tmp/big.txt"
head -c 40000 /dev/zero | tr '\0' a >"$big"
payload="$(jq -nc --arg c "$tmp" --arg f "$big" \
  '{session_id:"t",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:$f}}')"
out="$(printf '%s' "$payload" | "$node" "$plugin/hook.mjs" --agent claude-code)"
assert_eq "a 40 KB Read is denied" deny "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
case "$out" in *ctx_execute*) r=yes ;; *) r=no ;; esac
assert_eq "the denial points to ctx_execute" yes "$r"

# A small Read passes untouched.
small="$tmp/small.txt"
echo hello >"$small"
payload="$(jq -nc --arg c "$tmp" --arg f "$small" \
  '{session_id:"t",cwd:$c,hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:$f}}')"
out="$(printf '%s' "$payload" | "$node" "$plugin/hook.mjs" --agent claude-code)"
assert_eq "a small Read is not denied" "" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')"

# The MCP server starts and lists the ctx_* tools.
tools="$( (
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 3
) | timeout 30 "$node" "$plugin/server.mjs" --agent claude-code 2>/dev/null | jq -r 'select(.id==2) | .result.tools[].name' | sort | tr '\n' ' ')"
for t in ctx_batch ctx_execute ctx_index ctx_search; do
  case " $tools" in *" $t "*) r=listed ;; *) r=missing ;; esac
  assert_eq "$t is served" listed "$r"
done

exit "$fail"
