// Harness shims over hook-core.mjs. A shim takes `{ root, hooks }` (generated from a plugin's hooks
// manifest): hooks[] = { id, script, enforce, tools?, timeout? }, where `tools` is the harness's own tool
// pattern (`edit|write`), matched whole and `timeout` is whole seconds. Only tool.before is implemented:
// the blocking and rewrite path. Hooks of one call run one after the other (a rewrite feeds the next hook)
// and asynchronously, so the host's event loop is not blocked.
//
// `enforce`: a `block` hook's deny blocks the call. A `warn` hook never blocks: its deny becomes
// additionalContext where the harness has that channel (omp) and is dropped where it has none (Pi). A
// `block` hook that cannot start (missing script, EACCES) writes one stderr line per script, so the gate
// is not silently off. As in Claude, a `block` hook still fails open on a crash, a timeout or bad output.
//
// The handler's second argument (`ctx`) is read for `cwd` and `sessionId` when the event lacks them. Whether
// omp and Pi pass such a context object is UNVERIFIED; the fallback is process.cwd() and no session id.
import { join, isAbsolute } from "node:path";
import { toPayload, runHook } from "./hook-core.mjs";

// Compile each hook's tool pattern once, when the extension is built (matched whole).
const compile = (spec) => ({
  ...spec,
  hooks: spec.hooks.map((h) => ({ ...h, re: h.tools == null ? null : new RegExp(`^(?:${h.tools})$`) })),
});
const matches = (h, toolName) => h.re == null || h.re.test(toolName);

// Only a positive integer number of seconds is a timeout; anything else uses the runtime default, so a
// bad manifest value can never make spawnSync throw (a throw in an omp handler fails closed).
const timeoutMs = (t) => (Number.isInteger(t) && t > 0 ? t * 1000 : undefined);

const reported = new Set();
// A block hook that did not run (cannot start, timed out, crashed, killed) fails open, as in Claude; say so
// once per script so the gate is not silently off.
const reportNotRun = (h, script, reason) => {
  if (h.enforce !== "block" || reported.has(script)) return;
  reported.add(script);
  process.stderr.write(`agent-env hook ${h.id}: ${reason}; its block gate did not run\n`);
};

// Run the matching hooks in manifest order against one tool call. The first block-hook deny wins, and a
// rewrite feeds the next hook's payload. An `asked` deny (ask or defer) is a gate for any `enforce`. `warnDeny`: "context" turns a warn hook's deny into context,
// "drop" discards it. Returns { deny, reason } | { input?, additionalContext? } | null.
async function runToolBefore(spec, ev, ctx, warnDeny) {
  let input = ev.input;
  let rewritten = false;
  let blockRewrite = false; // a block hook produced a rewrite
  const context = [];
  for (const h of spec.hooks) {
    if (!matches(h, ev.toolName)) continue;
    const script = isAbsolute(h.script) ? h.script : join(spec.root, h.script);
    const r = await runHook({
      script,
      timeoutMs: timeoutMs(h.timeout),
      payload: toPayload({
        event: "PreToolUse",
        toolName: ev.toolName,
        input,
        sessionId: ev.sessionId ?? ctx?.sessionId,
        cwd: ev.cwd ?? ctx?.cwd ?? process.cwd(),
      }),
    });
    if (r.unrunnable) reportNotRun(h, script, `cannot run ${script} (${r.unrunnable})`);
    if (r.failed) reportNotRun(h, script, `${script} ${r.failed}`);
    if (r.deny) {
      if (h.enforce !== "warn" || r.asked) return { deny: true, reason: r.reason };
      if (warnDeny === "context") context.push(`warning: ${r.reason}`);
      continue;
    }
    if (r.updatedInput) {
      input = r.updatedInput;
      rewritten = true;
      if (h.enforce === "block") blockRewrite = true;
    }
    if (r.additionalContext) context.push(r.additionalContext);
  }
  if (!rewritten && context.length === 0) return null;
  return { input: rewritten ? input : undefined, blockRewrite, additionalContext: context.length ? context.join("\n") : undefined };
}

// oh-my-pi: `tool_call` returns { block, reason, input, additionalContext } (docs v19.0.0).
export const ompExtension = (rawSpec) => (pi) => {
  const spec = compile(rawSpec);
  pi.on("tool_call", async (ev, ctx) => {
    const r = await runToolBefore(spec, ev, ctx, "context");
    if (!r) return undefined;
    if (r.deny) return { block: true, reason: r.reason };
    const out = {};
    if (r.input) out.input = r.input;
    if (r.additionalContext) out.additionalContext = r.additionalContext;
    return out;
  });
};

// Replace the contents of `target` with `next`, whole or not at all: refuse a non-object, a non-extensible
// object or one with a non-configurable key, and restore the original if the write still fails.
function applyInPlace(target, next) {
  if (!target || typeof target !== "object" || Array.isArray(target) || !Object.isExtensible(target)) return false;
  const saved = Object.getOwnPropertyDescriptors(target);
  if (Object.values(saved).some((d) => !d.configurable)) return false;
  try {
    for (const k of Object.keys(target)) delete target[k];
    Object.assign(target, next);
    return true;
  } catch {
    for (const k of Object.keys(target)) delete target[k];
    Object.defineProperties(target, saved);
    return false;
  }
}

// Pi: `tool_call` blocks with { block, reason } and rewrites by mutating event.input (docs v1.5.2).
// Pi has no context-injection channel on tool_call, so additionalContext and a warn hook's deny are dropped.
export const piExtension = (rawSpec) => (pi) => {
  const spec = compile(rawSpec);
  pi.on("tool_call", async (ev, ctx) => {
    const r = await runToolBefore(spec, ev, ctx, "drop");
    if (!r) return undefined;
    if (r.deny) return { block: true, reason: r.reason };
    if (r.input && !applyInPlace(ev.input, r.input)) {
      process.stderr.write(`agent-env hook: cannot rewrite the ${ev.toolName} input in place; rewrite skipped\n`);
      if (r.blockRewrite) return { block: true, reason: "cannot apply the rewrite on this harness" };
    }
    return undefined;
  });
};
