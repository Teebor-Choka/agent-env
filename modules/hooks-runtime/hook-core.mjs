// Neutral hook runtime: run one hook script with a Claude-shaped payload on stdin and read its decision.
// The scripts are written once, for Claude Code's contract; the harness shims (adapters.mjs) translate
// their native events to this payload and the decision back. Contract, as in Claude: exit 2 or a JSON
// `permissionDecision: "deny"` blocks, `updatedInput` rewrites the tool input, `additionalContext`
// injects text. The harnesses behind these shims cannot ask the user, so `ask` and `defer` deny with a
// "needs confirmation" reason. Any other failure (exit 1, a timeout, a crash, bad output) does not block:
// a `block` hook still fails open there, as in Claude. The runner is async (the host's event loop keeps
// running) and says why a hook did not run: `unrunnable` (missing script, EACCES) or `failed` (timeout,
// non-0/2 exit, signal, output over the cap), so the shim can report that a block gate did not run.
import { spawn } from "node:child_process";

const CLAUDE_TOOL = {
  bash: "Bash",
  shell: "Bash",
  powershell: "Bash", // the shell alias: scripts read tool_input.command as for Bash
  read: "Read",
  edit: "Edit",
  write: "Write",
  ast_edit: "Edit",
  grep: "Grep",
  glob: "Glob",
  find: "Glob",
  ls: "Glob",
  task: "Agent",
  subagent: "Agent",
  ask: "AskUserQuestion",
  question: "AskUserQuestion",
};

// tool_input is passed through UNTRANSLATED. omp and Pi edit and search tools use their own field names, so a
// Claude-written hook keyed on file_path or pattern may not match there. Known to carry the same field as
// Claude: shell (`command`). Everything else is unverified; do not assume.
// Object.hasOwn: `constructor` and `toString` are not tools.
export const claudeToolName = (native) => (Object.hasOwn(CLAUDE_TOOL, native) ? CLAUDE_TOOL[native] : native);

export const toPayload = ({ event, toolName, input, sessionId, cwd }) => ({
  hook_event_name: event,
  tool_name: claudeToolName(toolName),
  tool_input: input,
  session_id: sessionId,
  cwd,
});

// Claude's command-hook default.
export const DEFAULT_TIMEOUT_MS = 60_000;
const MAX_BUFFER = 16 * 1024 * 1024;
const DENY_DEFAULT = "blocked by a hook";
const CONFIRM = "needs confirmation: ";

// Run the script in its own process group (so a timeout also reaches children that hold the pipes) and
// collect { status, signal, stdout, stderr, error, timedOut, overflow }. A broken stdin pipe (a hook that
// answers without reading a large payload) is ignored: the exit status and stdout decide.
function exec(script, input, timeoutMs) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(script, [], { stdio: ["pipe", "pipe", "pipe"], detached: true });
    } catch (error) {
      resolve({ error });
      return;
    }
    const r = { stdout: "", stderr: "", timedOut: false, overflow: false };
    let done = false;
    let grace;
    const killGroup = () => {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        try { child.kill("SIGKILL"); } catch {}
      }
    };
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      clearTimeout(grace);
      resolve(r);
    };
    const timer = setTimeout(() => {
      r.timedOut = true;
      killGroup();
      finish();
    }, timeoutMs);
    const collect = (key) => (d) => {
      if (r.overflow) return;
      r[key] += d;
      if (r[key].length > MAX_BUFFER) {
        r.overflow = true;
        killGroup();
        finish();
      }
    };
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", collect("stdout"));
    child.stderr.on("data", collect("stderr"));
    child.stdin.on("error", () => {});
    child.on("error", (error) => {
      r.error = error;
      finish();
    });
    // exit comes before the pipes drain; a grandchild that keeps them open must not hold the result.
    child.on("exit", (status, signal) => {
      r.status = status;
      r.signal = signal;
      grace = setTimeout(finish, 200);
    });
    child.on("close", finish);
    child.stdin.end(input);
  });
}

export async function runHook({ script, payload, timeoutMs }) {
  const ms = Number.isInteger(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS;
  const r = await exec(script, JSON.stringify(payload), ms);
  if (r.error) return { unrunnable: r.error.code ?? String(r.error.message) };
  if (r.timedOut) return { failed: `timed out after ${ms / 1000}s` };
  if (r.overflow) return { failed: "output over 16 MiB" };
  if (r.signal) return { failed: `killed by ${r.signal}` };
  if (r.status === 2) return { deny: true, reason: r.stderr.trim() || DENY_DEFAULT };
  if (r.status !== 0) return { failed: `exit ${r.status}` };
  let parsed;
  try {
    parsed = JSON.parse(r.stdout);
  } catch {
    return {};
  }
  if (parsed?.decision === "block") return { deny: true, reason: parsed.reason || DENY_DEFAULT }; // legacy top-level shape
  const out = parsed?.hookSpecificOutput;
  if (!out || typeof out !== "object") return {};
  if (out.permissionDecision === "deny") {
    return { deny: true, reason: out.permissionDecisionReason || DENY_DEFAULT };
  }
  if (out.permissionDecision === "ask" || out.permissionDecision === "defer") {
    return { deny: true, reason: CONFIRM + (out.permissionDecisionReason || "a hook asked for confirmation"), asked: true };
  }
  const result = {};
  const ui = out.updatedInput;
  if (ui && typeof ui === "object" && !Array.isArray(ui)) result.updatedInput = ui;
  if (typeof out.additionalContext === "string") result.additionalContext = out.additionalContext;
  return result;
}
