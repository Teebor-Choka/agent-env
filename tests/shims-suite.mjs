// Tests for modules/hooks-runtime: the neutral hook runtime behind the oh-my-pi and Pi shims. Real sh
// scripts, a fake host that records `pi.on(...)` handlers, no network. Run: node tests/shims-suite.mjs
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, chmodSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { claudeToolName, toPayload, runHook } from "../modules/hooks-runtime/hook-core.mjs";
import { ompExtension, piExtension } from "../modules/hooks-runtime/adapters.mjs";

let failed = 0;
const eq = (label, want, got) => {
  const w = JSON.stringify(want), g = JSON.stringify(got);
  if (w === g) console.log(`ok   ${label}`);
  else { console.log(`FAIL ${label}: expected ${w}, got ${g}`); failed = 1; }
};

const dir = mkdtempSync(join(tmpdir(), "shims-"));
const script = (name, body) => {
  const p = join(dir, name);
  writeFileSync(p, `#!/bin/sh\n${body}\n`);
  chmodSync(p, 0o755);
  return p;
};
const seen = join(dir, "seen.json");
const record = script("record", `cat > ${seen}`);
const deny2 = script("deny2", `echo "no force push" >&2; exit 2`);
const denyJson = script("denyjson", `cat >/dev/null; echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"policy says no"}}'`);
const rewrite = script("rewrite", `cat >/dev/null; echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"echo rewritten"}}}'`);
const context = script("context", `cat >/dev/null; echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"use the graph"}}'`);
const crash = script("crash", `exit 1`);
const slow = script("slow", `sleep 5`);
const garbage = script("garbage", `cat >/dev/null; echo 'not json'`);

// --- core: tool names and payload shape ---
eq("bash is Bash", "Bash", claudeToolName("bash"));
eq("edit is Edit", "Edit", claudeToolName("edit"));
eq("task is Agent", "Agent", claudeToolName("task"));
eq("ask is AskUserQuestion", "AskUserQuestion", claudeToolName("ask"));
eq("powershell is Bash (the shell alias)", "Bash", claudeToolName("powershell"));
eq("an unknown tool keeps its name", "mytool", claudeToolName("mytool"));
eq("payload is Claude-shaped", { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" }, session_id: "s1", cwd: "/w" },
  toPayload({ event: "PreToolUse", toolName: "bash", input: { command: "ls" }, sessionId: "s1", cwd: "/w" }));

// --- core: running a hook and reading its decision ---
let r = await runHook({ script: record, payload: { tool_name: "Bash", tool_input: { command: "ls" } } });
eq("an allowing hook returns no decision", {}, r);
eq("the script received the payload on stdin", "ls", JSON.parse(readFileSync(seen, "utf8")).tool_input.command);
r = await runHook({ script: deny2, payload: {} });
eq("exit 2 denies with stderr as the reason", { deny: true, reason: "no force push" }, r);
r = await runHook({ script: denyJson, payload: {} });
eq("a JSON deny carries its reason", { deny: true, reason: "policy says no" }, r);
r = await runHook({ script: rewrite, payload: {} });
eq("updatedInput is returned", { updatedInput: { command: "echo rewritten" } }, r);
r = await runHook({ script: context, payload: {} });
eq("additionalContext is returned", { additionalContext: "use the graph" }, r);
eq("exit 1 does not block (as in Claude), and is reported as a failure", { failed: "exit 1" }, await runHook({ script: crash, payload: {} }));
eq("a timeout does not block, and is reported", { failed: "timed out after 0.2s" }, await runHook({ script: slow, payload: {}, timeoutMs: 200 }));
eq("non-JSON stdout is ignored", {}, await runHook({ script: garbage, payload: {} }));
eq("a missing script does not block, and is reported as unrunnable", { unrunnable: "ENOENT" }, await runHook({ script: join(dir, "nope"), payload: {} }));

// --- adapters: a fake host ---
const host = () => { const h = {}; return { on: (e, fn) => { h[e] = fn; }, h }; };
const spec = (hooks) => ({ root: dir, hooks });
const hk = (id, script, extra = {}) => ({ id, script, enforce: "block", ...extra });

let pi = host();
ompExtension(spec([hk("a", deny2, { tools: "bash" })]))(pi);
eq("omp registers tool_call", ["tool_call"], Object.keys(pi.h));
eq("omp blocks a matching tool", { block: true, reason: "no force push" }, await pi.h.tool_call({ toolName: "bash", input: { command: "x" } }));
eq("omp ignores a tool the hook does not match", undefined, await pi.h.tool_call({ toolName: "read", input: {} }));
eq("the tool pattern is anchored (bashful is not bash)", undefined, await pi.h.tool_call({ toolName: "bashful", input: {} }));

pi = host();
ompExtension(spec([hk("a", deny2, { tools: "edit|write" })]))(pi);
eq("an alternation matches each name", { block: true, reason: "no force push" }, await pi.h.tool_call({ toolName: "write", input: {} }));

pi = host();
ompExtension(spec([hk("a", record)]))(pi);
await pi.h.tool_call({ toolName: "anything", input: {} });
eq("a hook with no tools matches every tool, and an unknown name passes through exactly", "anything", JSON.parse(readFileSync(seen, "utf8")).tool_name);

pi = host();
ompExtension(spec([hk("a", rewrite, { tools: "bash" })]))(pi);
eq("omp returns the rewritten input", { input: { command: "echo rewritten" } }, await pi.h.tool_call({ toolName: "bash", input: { command: "rm -rf /" } }));

pi = host();
ompExtension(spec([hk("a", context, { tools: "bash" })]))(pi);
eq("omp returns additionalContext", { additionalContext: "use the graph" }, await pi.h.tool_call({ toolName: "bash", input: {} }));

pi = host();
ompExtension(spec([hk("a", rewrite, { tools: "bash" }), hk("b", record, { tools: "bash" })]))(pi);
await pi.h.tool_call({ toolName: "bash", input: { command: "orig" } });
eq("a later hook sees the earlier hook's rewrite", "echo rewritten", JSON.parse(readFileSync(seen, "utf8")).tool_input.command);

pi = host();
ompExtension(spec([hk("a", deny2, { tools: "bash" }), hk("b", record, { tools: "bash" })]))(pi);
writeFileSync(seen, "{}");
await pi.h.tool_call({ toolName: "bash", input: { command: "x" } });
eq("the first deny stops the chain", {}, JSON.parse(readFileSync(seen, "utf8")));

// Pi mutates event.input in place and returns { block, reason }
pi = host();
piExtension(spec([hk("a", deny2, { tools: "bash" })]))(pi);
eq("pi blocks", { block: true, reason: "no force push" }, await pi.h.tool_call({ toolName: "bash", input: {} }));
pi = host();
piExtension(spec([hk("a", rewrite, { tools: "bash" })]))(pi);
const ev = { toolName: "bash", input: { command: "rm -rf /" } };
const out = await pi.h.tool_call(ev);
eq("pi rewrites event.input in place", { command: "echo rewritten" }, ev.input);
eq("pi returns nothing when it only rewrote", undefined, out);

// --- R1: every hook's additionalContext is kept, joined in hook order ---
const ctxScript = (name, text) => script(name, `cat >/dev/null; echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"${text}"}}'`);
pi = host();
ompExtension(spec([hk("a", ctxScript("ctxa", "first"), { tools: "bash" }), hk("b", ctxScript("ctxb", "second"), { tools: "bash" })]))(pi);
eq("omp joins the additionalContext of two hooks with a newline, in hook order", { additionalContext: "first\nsecond" }, await pi.h.tool_call({ toolName: "bash", input: {} }));

// --- R6: ask, defer and the legacy block cannot be asked here, so they deny ---
const decide = (name, json) => script(name, `cat >/dev/null; echo '${json}'`);
const hso = (o) => JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", ...o } });
eq("ask denies with a needs-confirmation reason", { deny: true, reason: "needs confirmation: really?", asked: true },
  await runHook({ script: decide("ask", hso({ permissionDecision: "ask", permissionDecisionReason: "really?" })), payload: {} }));
eq("defer denies with a needs-confirmation reason", { deny: true, reason: "needs confirmation: later", asked: true },
  await runHook({ script: decide("defer", hso({ permissionDecision: "defer", permissionDecisionReason: "later" })), payload: {} }));
eq("ask without a reason still names the confirmation", { deny: true, reason: "needs confirmation: a hook asked for confirmation", asked: true },
  await runHook({ script: decide("askbare", hso({ permissionDecision: "ask" })), payload: {} }));
eq("ask drops updatedInput", { deny: true, reason: "needs confirmation: really?", asked: true },
  await runHook({ script: decide("askrw", hso({ permissionDecision: "ask", permissionDecisionReason: "really?", updatedInput: { command: "x" } })), payload: {} }));
eq("deny drops updatedInput", { deny: true, reason: "no" },
  await runHook({ script: decide("denyrw", hso({ permissionDecision: "deny", permissionDecisionReason: "no", updatedInput: { command: "x" } })), payload: {} }));
eq("the legacy top-level block denies with its reason", { deny: true, reason: "legacy no" },
  await runHook({ script: decide("legacy", JSON.stringify({ decision: "block", reason: "legacy no" })), payload: {} }));
eq("an empty stderr reason is 'blocked by a hook'", { deny: true, reason: "blocked by a hook" }, await runHook({ script: script("bare2", "exit 2"), payload: {} }));
eq("a string updatedInput is ignored", {}, await runHook({ script: decide("rwstr", hso({ updatedInput: "rm -rf /" })), payload: {} }));
eq("an array updatedInput is ignored", {}, await runHook({ script: decide("rwarr", hso({ updatedInput: ["x"] })), payload: {} }));

// --- R8: a bad timeout never reaches spawnSync ---
const nap200 = script("nap200", `sleep 0.2; echo "no force push" >&2; exit 2`);
for (const t of [0, "30s", -1, 1.5, NaN, null]) {
  pi = host();
  ompExtension(spec([hk("a", nap200, { tools: "bash", timeout: t })]))(pi);
  let out;
  try { out = await pi.h.tool_call({ toolName: "bash", input: {} }); } catch (e) { out = `threw ${e.code ?? e.message}`; }
  eq(`timeout ${JSON.stringify(t)} (${typeof t}) is ignored, the hook still runs`, { block: true, reason: "no force push" }, out);
}
for (const t of [0, -1, NaN, "x", 1.5]) eq(`runHook timeoutMs ${t} falls back to the default (a 200 ms hook is not cut off)`, { deny: true, reason: "no force push" }, await runHook({ script: nap200, payload: {}, timeoutMs: t }));

// --- R11: seconds become milliseconds in the adapter ---
const napDeny = script("napdeny", `sleep 0.5; echo "late no" >&2; exit 2`);
pi = host();
ompExtension(spec([hk("a", napDeny, { tools: "bash", timeout: 2 })]))(pi);
eq("timeout 2 is two seconds, not two milliseconds", { block: true, reason: "late no" }, await pi.h.tool_call({ toolName: "bash", input: {} }));
pi = host();
ompExtension(spec([hk("a", slow, { tools: "bash", timeout: 1 })]))(pi);
const t0 = Date.now();
eq("timeout 1 fails open after about a second", undefined, await pi.h.tool_call({ toolName: "bash", input: {} }));
eq("and it was cut off near one second", true, Date.now() - t0 < 4000);

// --- R5: enforce has a runtime effect ---
pi = host();
ompExtension(spec([hk("a", deny2, { tools: "bash", enforce: "warn" })]))(pi);
eq("omp: a warn hook that denies becomes additionalContext", { additionalContext: "warning: no force push" }, await pi.h.tool_call({ toolName: "bash", input: {} }));
pi = host();
piExtension(spec([hk("a", deny2, { tools: "bash", enforce: "warn" })]))(pi);
eq("pi: a warn hook that denies is dropped (no channel)", undefined, await pi.h.tool_call({ toolName: "bash", input: {} }));
pi = host();
ompExtension(spec([hk("a", deny2, { tools: "bash", enforce: "warn" }), hk("b", ctxScript("ctxw", "also"), { tools: "bash", enforce: "warn" })]))(pi);
eq("a denied warn hook does not stop the chain", { additionalContext: "warning: no force push\nalso" }, await pi.h.tool_call({ toolName: "bash", input: {} }));
const captureStderr = async (fn) => {
  const lines = [];
  const orig = process.stderr.write.bind(process.stderr);
  process.stderr.write = (c) => { lines.push(String(c)); return true; };
  try { await fn(); } finally { process.stderr.write = orig; }
  return lines;
};
const noexec = join(dir, "noexec");
writeFileSync(noexec, "#!/bin/sh\nexit 2\n");
chmodSync(noexec, 0o644);
pi = host();
ompExtension(spec([hk("gate", noexec, { tools: "bash" })]))(pi);
let lines = await captureStderr(async () => {
  eq("a block hook that cannot run (EACCES) fails open", undefined, await pi.h.tool_call({ toolName: "bash", input: {} }));
  await pi.h.tool_call({ toolName: "bash", input: {} });
});
eq("EACCES on a block hook writes one stderr line, once per script", 1, lines.length);
eq("and the line names the hook, the script and the code", true, /gate/.test(lines[0] ?? "") && (lines[0] ?? "").includes(noexec) && /EACCES/.test(lines[0] ?? ""));
const missing = join(dir, "no-such-script");
pi = host();
ompExtension(spec([hk("gone", missing, { tools: "bash" })]))(pi);
lines = await captureStderr(() => pi.h.tool_call({ toolName: "bash", input: {} }));
eq("a missing script on a block hook is reported too", true, lines.length === 1 && /ENOENT/.test(lines[0]));
pi = host();
ompExtension(spec([hk("w", join(dir, "no-such-warn"), { tools: "bash", enforce: "warn" })]))(pi);
lines = await captureStderr(() => pi.h.tool_call({ toolName: "bash", input: {} }));
eq("a warn hook that cannot run stays quiet", 0, lines.length);

// --- R10: robustness ---
const noisy = script("noisy", `head -c 2000000 /dev/zero | tr '\\0' x; echo "big no" >&2; exit 2`);
eq("2 MB of stdout does not hide an exit-2 deny (maxBuffer)", { deny: true, reason: "big no" }, await runHook({ script: noisy, payload: {} }));
const early = script("early", `echo "early no" >&2; exit 2`);
const bigPayload = { tool_input: { command: "x".repeat(3_000_000) } };
eq("precondition: spawnSync reports EPIPE for a hook that exits without reading", "EPIPE",
  spawnSync(early, [], { input: JSON.stringify(bigPayload), encoding: "utf8" }).error?.code);
eq("an exit-2 hook that never reads a large payload still denies (EPIPE)", { deny: true, reason: "early no" }, await runHook({ script: early, payload: bigPayload }));
pi = host();
piExtension(spec([hk("a", rewrite, { tools: "bash" })]))(pi);
const frozen = Object.freeze({ command: "orig" });
lines = await captureStderr(async () => {
  eq("pi: a block hook whose rewrite cannot be applied denies", { block: true, reason: "cannot apply the rewrite on this harness" }, await pi.h.tool_call({ toolName: "bash", input: frozen }));
});
eq("a frozen input is left alone and one stderr line says so", [{ command: "orig" }, 1], [frozen, lines.length]);
lines = await captureStderr(async () => {
  eq("pi: a rewrite on a non-object input denies too", { block: true, reason: "cannot apply the rewrite on this harness" }, await pi.h.tool_call({ toolName: "bash", input: "just a string" }));
});
eq("a non-object input gets one stderr line", 1, lines.length);
pi = host();
ompExtension(spec([hk("a", record, { tools: "bash" })]))(pi);
await pi.h.tool_call({ toolName: "bash", input: {} }, { cwd: "/ctx/cwd", sessionId: "ctx-sid" });
eq("the handler's second argument supplies cwd and sessionId (UNVERIFIED host shape)", ["/ctx/cwd", "ctx-sid"],
  [JSON.parse(readFileSync(seen, "utf8")).cwd, JSON.parse(readFileSync(seen, "utf8")).session_id]);

// --- R11: the generated shim text, imported and run against adapters.mjs ---
let shimFile = process.argv[2];
if (!shimFile) {
  const here = dirname(fileURLToPath(import.meta.url));
  mkdirSync(join(dir, "shimroot", "hooks"), { recursive: true });
  const gate = join(dir, "shimroot", "hooks", "deny");
  writeFileSync(gate, "#!/bin/sh\necho 'from the generated shim' >&2\nexit 2\n");
  chmodSync(gate, 0o755);
  const expr = `let lib = import <nixpkgs/lib>; plugins = import ${here}/../modules/home/agent-plugins-lib.nix { inherit lib; }; l = import ${here}/../modules/home/agent-hooks-lib.nix { inherit lib plugins; }; in l.renderShim { harness = "omp"; manifest = { hooks = [ { id = "g"; event = "tool.before"; tools = [ "file.edit" ]; script = "hooks/deny"; enforce = "block"; } ]; }; root = "${join(dir, "shimroot")}"; runtime = "${here}/../modules/hooks-runtime"; }`;
  const n = spawnSync("nix", ["eval", "--impure", "--raw", "--expr", expr], { encoding: "utf8" });
  if (n.status === 0) { shimFile = join(dir, "shim.mjs"); writeFileSync(shimFile, n.stdout); }
  else {
    const why = (n.stderr || String(n.error)).trim().split("\n").pop();
    if (process.env.CI) eq("the generated shim could be built (CI must not skip it)", true, `nix eval failed: ${why}`);
    else console.log(`SKIP generated shim tests: nix eval failed (${why}); pass a shim file as argv[2] or run where nix works`);
  }
}
if (shimFile) {
  const mod = await import(pathToFileURL(shimFile).href);
  pi = host();
  mod.default(pi);
  eq("the generated shim registers tool_call", ["tool_call"], Object.keys(pi.h));
  eq("the generated shim blocks write through adapters.mjs", { block: true, reason: "from the generated shim" }, await pi.h.tool_call({ toolName: "write", input: {} }));
  eq("the generated shim ignores bash", undefined, await pi.h.tool_call({ toolName: "bash", input: {} }));
}

// --- S1: an ask or defer is a gate whatever `enforce` says ---
const askWarn = script("askwarn", `cat >/dev/null; echo '${hso({ permissionDecision: "ask", permissionDecisionReason: "sure?" })}'`);
eq("runHook marks ask as asked", { deny: true, reason: "needs confirmation: sure?", asked: true }, await runHook({ script: askWarn, payload: {} }));
pi = host();
ompExtension(spec([hk("a", askWarn, { tools: "bash", enforce: "warn" })]))(pi);
eq("omp: a warn hook that asks blocks", { block: true, reason: "needs confirmation: sure?" }, await pi.h.tool_call({ toolName: "bash", input: {} }));
pi = host();
piExtension(spec([hk("a", askWarn, { tools: "bash", enforce: "warn" })]))(pi);
eq("pi: a warn hook that asks blocks", { block: true, reason: "needs confirmation: sure?" }, await pi.h.tool_call({ toolName: "bash", input: {} }));
pi = host();
piExtension(spec([hk("a", deny2, { tools: "bash", enforce: "warn" })]))(pi);
eq("pi: a warn hook that plainly denies still does not block", undefined, await pi.h.tool_call({ toolName: "bash", input: {} }));

// --- S2: native names translate to Claude's ---
for (const [native, claude] of [["ast_edit", "Edit"], ["grep", "Grep"], ["glob", "Glob"], ["find", "Glob"], ["ls", "Glob"]])
  eq(`${native} is ${claude} in the payload`, claude, toPayload({ event: "PreToolUse", toolName: native, input: {} }).tool_name);

// --- S3: an EPIPE with exit 0 keeps the JSON decision ---
const denyEarly = script("denyearly", `echo '${hso({ permissionDecision: "deny", permissionDecisionReason: "json no" })}'`);
const bigPayload2 = { tool_input: { command: "y".repeat(300_000) } };
eq("precondition: the JSON-printing hook breaks the pipe", "EPIPE", spawnSync(denyEarly, [], { input: JSON.stringify(bigPayload2), encoding: "utf8" }).error?.code);
eq("a JSON deny survives an EPIPE on exit 0", { deny: true, reason: "json no" }, await runHook({ script: denyEarly, payload: bigPayload2 }));
eq("EPIPE with nothing to parse does not block", {}, await runHook({ script: script("quietearly", "exit 0"), payload: bigPayload2 }));

// --- S6: a rewrite is applied whole or not at all ---
const nonExt = Object.preventExtensions({ command: "orig" });
pi = host();
piExtension(spec([hk("a", rewrite, { tools: "bash" })]))(pi);
const lines6 = await captureStderr(async () => {
  eq("pi: a non-extensible input cannot take the rewrite, so a block hook denies", { block: true, reason: "cannot apply the rewrite on this harness" }, await pi.h.tool_call({ toolName: "bash", input: nonExt }));
});
eq("and the input keeps its original content", { command: "orig" }, nonExt);
pi = host();
piExtension(spec([hk("a", rewrite, { tools: "bash", enforce: "warn" })]))(pi);
const nonExt2 = Object.preventExtensions({ command: "orig" });
await captureStderr(async () => { eq("a warn hook's failed rewrite does not block", undefined, await pi.h.tool_call({ toolName: "bash", input: nonExt2 })); });
eq("and leaves the input intact", { command: "orig" }, nonExt2);

// --- C5: names that exist on Object.prototype are not tools ---
for (const n of ["constructor", "toString", "__proto__", "hasOwnProperty"]) eq(`${n} keeps its name`, n, claudeToolName(n));

// --- C2: runHook is async and does not block the event loop ---
let ticks = 0;
const iv = setInterval(() => ticks++, 20);
await runHook({ script: script("nap300", "cat >/dev/null; sleep 0.3"), payload: {} });
clearInterval(iv);
eq("the event loop keeps running while a hook runs", true, ticks >= 5);
eq("runHook returns a promise", true, runHook({ script: crash, payload: {} }) instanceof Promise);
eq("a timed-out hook that left a child holding the pipe is still cut off", { failed: "timed out after 0.2s" },
  await runHook({ script: script("orphan", "sleep 5 & wait"), payload: {}, timeoutMs: 200 }));
eq("a hook killed by a signal is reported", { failed: "killed by SIGTERM" }, await runHook({ script: script("selfkill", "kill -TERM $$"), payload: {} }));
eq("output above the buffer cap is a failure, not a hang", { failed: "output over 16 MiB" },
  await runHook({ script: script("flood", "cat >/dev/null; yes x | head -c 20000000"), payload: {} }));
// hooks of one tool call run in order (a rewrite feeds the next hook)
pi = host();
ompExtension(spec([hk("a", rewrite, { tools: "bash" }), hk("b", record, { tools: "bash" })]))(pi);
await pi.h.tool_call({ toolName: "bash", input: { command: "orig" } });
eq("hooks of one call run sequentially, in order", "echo rewritten", JSON.parse(readFileSync(seen, "utf8")).tool_input.command);

// --- C1: a block hook that times out, crashes or is killed says so once per script ---
const reportCases = [
  ["slowgate", `sleep 5`, 1, /timed out/],
  ["crashgate", `exit 1`, undefined, /exit 1/],
  ["killgate", `kill -TERM $$`, undefined, /killed by SIGTERM/],
];
for (const [name, body, timeout, re] of reportCases) {
  pi = host();
  ompExtension(spec([hk(name, script(name, body), { tools: "bash", timeout })]))(pi);
  lines = await captureStderr(async () => {
    eq(`${name}: the call is not blocked (fails open)`, undefined, await pi.h.tool_call({ toolName: "bash", input: {} }));
    await pi.h.tool_call({ toolName: "bash", input: {} });
  });
  eq(`${name}: one stderr line, once per script`, 1, lines.length);
  eq(`${name}: the line names the hook and says the gate did not run`, true,
    lines[0]?.startsWith(`agent-env hook ${name}: `) && re.test(lines[0]) && lines[0].trimEnd().endsWith("; its block gate did not run"));
}
pi = host();
ompExtension(spec([hk("warncrash", script("warncrash", "exit 1"), { tools: "bash", enforce: "warn" })]))(pi);
lines = await captureStderr(() => pi.h.tool_call({ toolName: "bash", input: {} }));
eq("a warn hook that crashes stays quiet", 0, lines.length);
eq("the default timeout is 60 s", 60000, (await import("../modules/hooks-runtime/hook-core.mjs")).DEFAULT_TIMEOUT_MS);

// --- C6: tool patterns compile once per extension, not per call ---
{
  const R = RegExp;
  let built = 0;
  globalThis.RegExp = class extends R { constructor(...a) { super(...a); built++; } };
  pi = host();
  ompExtension(spec([hk("a", crash, { tools: "bash" }), hk("b", crash, { tools: "edit|write" })]))(pi);
  const atStart = built;
  for (let i = 0; i < 3; i++) await pi.h.tool_call({ toolName: "bash", input: {} });
  globalThis.RegExp = R;
  eq("no regex is built while handling calls", atStart, built);
}

rmSync(dir, { recursive: true, force: true });
process.exit(failed);
