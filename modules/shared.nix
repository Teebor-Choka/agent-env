# modules/shared.nix
# Settings shared by modules/agentic.nix (dev homes) and modules/sandbox.nix (sandboxes), so the
# proxy and MCP wiring cannot drift apart. Plain data, no module arguments.
{

  # Headroom proxy settings shared by the systemd unit and the launchd agent.
  # --anthropic-pre-upstream-concurrency auto-detects to max(2, min(8, cpu_count)), as low as 8
  # concurrent requests in the parse/compress/upstream-connect stage, the bottleneck for many
  # parallel sessions and subagents. --limit-concurrency and --max-connections default to 1000 and
  # 500. --no-rate-limit drops the default 60 requests per minute throttle (Anthropic enforces its
  # own limits). --no-cache drops the semantic response cache, which could answer a similar prompt
  # with a stale reply. --no-subscription-tracking stops the 300 s usage poll that only feeds /stats.
  headroomArgs = [
    "--backend"
    "anthropic"
    "--port"
    "8787"
    "--limit-concurrency"
    "2000"
    "--max-connections"
    "1000"
    "--anthropic-pre-upstream-concurrency"
    "256"
    "--no-rate-limit"
    "--no-cache"
    "--no-subscription-tracking"
  ];
  # No anonymous usage beacon, no daily PyPI update check (the version is pinned).
  headroomEnv = {
    HEADROOM_BEACON = "off";
    HEADROOM_UPDATE_CHECK = "off";
  };

  # Force-index wrapper for codebase-memory-mcp: harnesses without a Claude-Code-style
  # SessionStart hook (opencode, codex, omp) never trigger dotclaude's git-index hook, so the
  # graph would stay empty until someone runs index_repository by hand. Kick off an incremental
  # index in the background on every MCP server spawn (cheap on an already-indexed repo, same
  # reasoning as the git-reindex hook) then exec the real stdio server immediately -- never
  # blocks startup. Confirmed live: nodes/edges populate within a couple seconds of first spawn.
  #
  # Per-repo mkdir lock (same idiom as dotclaude's git-reindex hook): without it, every MCP
  # server spawn backgrounds a brand new index job with no guard against one already running.
  # Confirmed live -- a real opencode session over a few minutes stacked two concurrent `cce
  # index` processes, each pinning a CPU core on embedding computation, and the resulting
  # contention starved a THIRD cce serve's startup past opencode's 30s MCP timeout ("Operation
  # timed out after 30000ms"). The lock makes a repeat spawn skip straight to exec when an index
  # for this repo is already in flight, instead of queuing another one behind it.
  #
  # nice/ionice: codebase-memory-mcp is a single compiled binary (no multiprocessing pool observed,
  # unlike cce's embedding workers below) so hasn't actually shown this failure mode -- applied
  # anyway, on principle: a background bootstrap job should never be able to compete with the
  # foreground MCP server's own startup, consistently, not only where a crash happened to surface it.
  codebaseMemoryMcpCmd = [
    "sh"
    "-c"
    ''
      lock="$HOME/.cache/codebase-memory-index.$(printf '%s' "$PWD" | tr '/ ' '__').lock"
      mkdir -p "$HOME/.cache"
      if mkdir "$lock" 2>/dev/null; then
        (trap 'rmdir "$lock" 2>/dev/null || true' EXIT; nice -n 19 ionice -c3 codebase-memory-mcp cli index_repository "{\"repo_path\":\"$PWD\"}" >/dev/null 2>&1) &
      fi
      exec codebase-memory-mcp''
  ];
}
