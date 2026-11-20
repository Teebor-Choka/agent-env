#!/usr/bin/env bash
# Tests for modules/home/agent-hooks-lib.nix: Codex hooks.json rendering and the hook x harness
# coverage matrix. jq comparisons over tests/harness-cases.nix.
#   harness-suite.sh                  one pure `nix eval` (no VM); run anywhere
#   harness-suite.sh <json> <fixdir>  cases already evaluated (the flake check, in the sandbox)
set -euo pipefail
fail=0
norm() { jq -cS . <<<"$1" 2>/dev/null || printf '%s' "$1"; }
check() { # label want got  (JSON compared with sorted keys)
  if [ "$(norm "$2")" = "$(norm "$3")" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}
if [ $# -eq 2 ]; then
  out=$(cat "$1")
else
  cd "$(dirname "$0")/.."
  out=$(nix eval --impure --json --expr \
    "import ./tests/harness-cases.nix { lib = import <nixpkgs/lib>; fix = \"$PWD/tests/fixtures/hooks\"; }")
fi
get() { jq -c "$1" <<<"$out"; }

check "the five harnesses" '["claude","codex","omp","opencode","pi"]' "$(get '.harnesses')"

# --- Codex: Claude's JSON shape, Codex tool names and PLUGIN_ROOT ---
check "codex renders the gated manifest like Claude, with PLUGIN_ROOT" \
  '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"${PLUGIN_ROOT}/hooks/gate.sh\""}]}],"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"\"${PLUGIN_ROOT}/hooks/policy-context.sh\"","timeout":10}]}]}}' \
  "$(get '.codexGated')"
check "codex file.edit is apply_patch" '"apply_patch"' "$(get '.codexMulti.hooks.PreToolUse[0].matcher')"
check "codex agent.spawn is Agent" '"Agent"' "$(get '.codexMulti.hooks.PreToolUse[1].matcher')"
check "codex drops the hooks it cannot express (file.read, ask.user)" '2' "$(get '.codexMulti.hooks.PreToolUse | length')"
check "codex keeps the other events" '["PostToolUse","PreToolUse","SessionStart","Stop","SubagentStart"]' "$(get '.codexMulti.hooks | keys')"

# --- coverage matrix: harness -> hook id -> block | warn | n/a | unblockable ---
cov() { get ".coverage.$1"; }
check "claude covers every hook" \
  '{"after":"warn","ask-guard":"block","boot":"warn","done":"warn","edit-guard":"block","read-nudge":"warn","spawn-guard":"block","sub":"warn"}' "$(cov claude)"
check "codex: no read or ask tool hook" \
  '{"after":"warn-unverified","ask-guard":"n/a","boot":"warn-unverified","done":"warn-unverified","edit-guard":"block-unverified","read-nudge":"n/a","spawn-guard":"block-unverified","sub":"warn-unverified"}' "$(cov codex)"
# The JS shims (omp, pi, opencode) implement tool.before only: other events are n/a until a shim reads them.
check "omp: tool.before hooks only" \
  '{"after":"no-shim","ask-guard":"block","boot":"no-shim","done":"n/a","edit-guard":"block","read-nudge":"warn","spawn-guard":"block","sub":"no-shim"}' "$(cov omp)"
check "pi: tool.before hooks only, no subagents, no ask" \
  '{"after":"no-shim","ask-guard":"n/a","boot":"no-shim","done":"n/a","edit-guard":"block","read-nudge":"silent","spawn-guard":"n/a","sub":"n/a"}' "$(cov pi)"
check "a warn hook on Pi tool.before is silent: Pi has no output channel for it" '"silent"' "$(cov pi | jq '.["read-nudge"]')"
check "opencode 2.x: no shim yet (plugin API unverified), everything n/a" \
  '{"after":"no-shim","ask-guard":"no-shim","boot":"n/a","done":"n/a","edit-guard":"no-shim","read-nudge":"no-shim","spawn-guard":"no-shim","sub":"n/a"}' "$(cov opencode)"
check "gated manifest on opencode: no shim yet" \
  '{"policy-context":"n/a","policy-gate":"no-shim"}' "$(get '.coverageGated.opencode')"
check "enforce block on an event the harness cannot block is unblockable" \
  '{"x":"unblockable","y":"block"}' "$(get '.unblockable.claude')"
check "a block hook with only some aliases on the harness is partial (codex), full where all exist (pi)" \
  '{"claude":"block","codex":"partial","omp":"block","opencode":"no-shim","pi":"block"}' "$(get '.partial | map_values(.g)')"
check "raw matcher on a tool event: Claude only, n/a elsewhere" \
  '{"claude":"warn","codex":"claude-only","omp":"claude-only","opencode":"claude-only","pi":"claude-only"}' "$(get '.rawMatcherCoverage | map_values(.m)')"
check "codex renders nothing for a raw tool matcher" '{}' "$(get '.rawMatcherCodex.hooks')"
check "omp and pi shims read no hook with a raw tool matcher" '[[],[]]' "$(get '[.rawMatcherOmp, .rawMatcherPi]')"
check "file.search: claude warn, codex n/a (no such tool), omp and pi warn/silent, opencode n/a" \
  '{"claude":"warn","codex":"n/a","omp":"warn","opencode":"n/a","pi":"silent"}' "$(get '.searchCoverage | map_values(.s)')"
check "file.search on omp" '"grep|glob|find"' "$(get '.searchOmp[0].tools')"
check "file.search on pi" '"grep|find|ls"' "$(get '.searchPi[0].tools')"
check "codex drops a file.search hook" '{}' "$(get '.searchCodex.hooks')"
check "codex block/warn hooks are unverified (PLUGIN_ROOT)" '["block-unverified","warn-unverified"]' "$(get '[.coverage.codex["edit-guard"], .coverage.codex["after"]]')"
# --- C4: hooks left out of a shim are listed, with the reason ---
check "omp plan drops the raw-matcher hook with a reason" \
  '[{"id":"m","reason":"claude-only: a raw matcher on a tool event"}]' "$(get '.planRawOmp.dropped')"
check "omp plan drops the session.start hook as no-shim" \
  '[{"id":"policy-context","reason":"no-shim: the omp shim does not read session.start yet"}]' "$(get '.planGatedOmp.dropped')"
check "the plan's hooks equal the spec" "$(get '.shimOmpGated')" "$(get '.planGatedOmp.hooks')"
check "the generated module names each dropped hook in a comment at the top" \
  '"// hook policy-context is not in this shim: no-shim: the omp shim does not read session.start yet"' "$(get '.shimText | split("\n")[0]')"
check "a hook id with a newline cannot break out of the comment" '1' "$(get '.shimInjection | split("\n") | map(select(startswith("//"))) | length')"
# --- generated shim specs: the hooks a JS shim reads, with the harness's own tool patterns ---
check "omp spec: tool.before hooks with omp tool patterns, in manifest order" \
  '[{"id":"edit-guard","script":"hooks/edit-guard","enforce":"block","tools":"edit|write|ast_edit"},{"id":"read-nudge","script":"hooks/read-nudge","enforce":"warn","tools":"read"},{"id":"spawn-guard","script":"hooks/spawn-guard","enforce":"block","tools":"task"},{"id":"ask-guard","script":"hooks/ask-guard","enforce":"block","tools":"ask"}]' "$(get '.shimOmpMulti')"
check "pi spec: only the tools Pi has" '["edit-guard","read-nudge"]' "$(get '[.shimPiMulti[].id]')"
check "omp spec for the gated manifest: the shell gate only" \
  '[{"id":"policy-gate","script":"hooks/gate.sh","enforce":"block","tools":"bash"}]' "$(get '.shimOmpGated')"
check "mixed aliases join in listed order (omp)" '"bash|read"' "$(get '.shimOmpMixed[0].tools')"
check "mixed aliases join in listed order (pi)" '"bash|powershell|read"' "$(get '.shimPiMixed[0].tools')"
check "pi spec for the gated manifest: bash and powershell" \
  '[{"id":"policy-gate","script":"hooks/gate.sh","enforce":"block","tools":"bash|powershell"}]' "$(get '.shimPiGated')"
check "the exact message for a shim without an adapter" '"no shim for opencode"' "$(get '.shimOpencodeError')"
check "partial outranks silent (pi warn, w) and unblockable (codex tool.after block, u)" \
  '{"pi":{"u":"no-shim","w":"partial"},"codex":{"u":"partial","w":"partial"}}' "$(get '.partialSilent | {pi: {u: .pi.u, w: .pi.w}, codex: {u: .codex.u, w: .codex.w}}')"
check "a shim for a harness with no adapter (opencode) is an error" 'true' "$(get '.shimOpencodeFails')"
if [ $# -ne 2 ]; then
  err=$(nix eval --impure --json --expr "
    (import ./modules/home/agent-hooks-lib.nix { lib = import <nixpkgs/lib>; plugins = import ./modules/home/agent-plugins-lib.nix { lib = import <nixpkgs/lib>; }; }).renderShim
      { harness = \"opencode\"; manifest = { hooks = [ ]; }; root = \"/r\"; runtime = \"/rt\"; }" 2>&1 >/dev/null || true)
  check "the error says no shim for opencode" '1' "$(grep -cF 'no shim for opencode' <<<"$err" || true)"
fi
check "a spec for a JSON harness is an error" 'true' "$(get '.shimCodexFails')"
shim=$(jq -r .shimText <<<"$out")
check "shim text imports the omp adapter from the runtime" '1' "$(grep -cF 'import { ompExtension } from "/store/runtime/adapters.mjs";' <<<"$shim" || true)"
check "shim text bakes the plugin root" '1' "$(grep -cF '"root":"/store/plugin"' <<<"$shim" || true)"
check "shim text exports the extension" '1' "$(grep -cF 'export default ompExtension(' <<<"$shim" || true)"
exit $fail
