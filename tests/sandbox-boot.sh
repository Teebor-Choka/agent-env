#!/usr/bin/env bash
# Live acceptance for nixosModules.sandbox: boot it in a sandy VM and check the environment from
# inside the guest. Needs a hypervisor, so it is NOT run in CI; run it before every bump.
#   nix run .#test-sandbox                 uses `sandy` and `vfkit` from PATH (or $SANDY)
#   nix run .#test-sandbox -- <flake dir>  test another checkout (default: this flake)
set -uo pipefail

flake=${1:-$PWD}
sandy=${SANDY:-sandy}
command -v "$sandy" >/dev/null || { echo "sandy not found (set SANDY=/path/to/sandy)" >&2; exit 2; }

fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# The guest needs more than sandy's 512 MiB default: the proxy alone holds about 240 MB, and the
# kernel OOM-kills it when a harness runs next to it.
mem=${SANDBOX_MEM:-2048}

run_in_guest() { # flake-dir attr script: run the script as the job in a fresh sandbox VM
  "$sandy" run --mem "$mem" --flake "path:$1" --kind nixos-module --attr "$2" -- sh -c "$3" 2>&1
}

# Everything the sandbox promises, checked from inside one boot. sandy returns only the guest's exit
# code, so each check has its own code and the host names the failure from it. The job runs as root
# (sandy autologins root); the checks about the user run as `user` through runuser, the way a job
# would.
as_user='runuser -u user --'
guest_script='
for i in $(seq 120); do curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null && break; sleep 1; done
curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null || exit 10
id -u user >/dev/null 2>&1 || exit 11
[ "$(runuser -u user -- sh -c "echo \$(id -un):\$HOME")" = user:/home/user ] || exit 12
runuser -u user -- sh -c "command -v claude >/dev/null && claude --version >/dev/null" || exit 13
runuser -u user -- jq -e ".hasCompletedOnboarding and .mcpServers[\"codebase-memory-mcp\"].alwaysLoad" /home/user/.claude.json >/dev/null || exit 14
runuser -u user -- jq -e ".env.DISABLE_TELEMETRY == \"1\"" /home/user/.claude/settings.json >/dev/null || exit 15
runuser -u user -- sh -c "[ \"\$(stat -c %U /home/user/.claude.json)\" = user ] && [ ! -L /home/user/.claude.json ] && [ -w /home/user/.claude.json ] && touch /home/user/probe" || exit 16
[ "$(runuser -u user -- sh -c "echo \$ANTHROPIC_BASE_URL")" = http://127.0.0.1:8787 ] || exit 17
[ "$(systemctl show headroom-proxy -p DynamicUser --value)" = yes ] || exit 18
systemctl list-unit-files 2>/dev/null | grep -q home-manager && exit 19
curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null || exit 20
exit 0'
declare -A reason=(
  [10]="headroom does not answer /health"
  [11]="the user account does not exist"
  [12]="the job as the user does not get its own identity and HOME"
  [13]="claude is not runnable as the user"
  [14]="~/.claude.json lacks onboarding or the always-loaded MCP server"
  [15]="~/.claude/settings.json lacks the telemetry opt-out"
  [16]="the user home files are not real, user-owned, writable files"
  [17]="ANTHROPIC_BASE_URL does not reach the user job and the proxy"
  [18]="the proxy is not a DynamicUser service"
  [19]="home-manager is present in the sandbox"
  [20]="the proxy died while the harness ran (out of memory?)"
)
out=$(run_in_guest "$flake" sandbox "$guest_script")
code=$(printf '%s' "$out" | sed -n 's/.*guest exit \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ "$code" = 0 ]; then
  pass "user@sandbox: basic user with a minimal home, claude as that user, proxy up, no home-manager"
else
  bad "sandbox check failed: ${reason[${code:-x}]:-no guest exit code (boot or build failed, or the guest ran out of memory: SANDBOX_MEM=$mem MiB)}"
  echo "$out" | tail -6
fi

# All three harnesses, in a second boot: a throwaway flake picks sandbox.tools. Each tool must run
# as the user with its config in place, and the proxy must still be alive afterwards.
# nix refuses a path: flake reached through a symlink, and /tmp is one on macOS.
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/flake.nix" <<NIX
{
  inputs.agent-env.url = "path:$flake";
  outputs = { agent-env, ... }: {
    nixosModules.all = {
      imports = [ agent-env.nixosModules.sandbox ];
      sandbox.tools = [ "claude" "opencode" "codex" ];
    };
  };
}
NIX
all_script='
for i in $(seq 120); do curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null && break; sleep 1; done
curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null || exit 10
runuser -u user -- sh -c "claude --version >/dev/null" || exit 11
runuser -u user -- sh -c "codex --version >/dev/null" || exit 12
runuser -u user -- sh -c "opencode --version >/dev/null" || exit 13
runuser -u user -- grep -q analytics /home/user/.codex/config.toml || exit 14
runuser -u user -- jq -e ".mcp[\"codebase-memory-mcp\"].type == \"local\" and .autoupdate == false" /home/user/.config/opencode/opencode.json >/dev/null || exit 15
[ "$(stat -c %U /home/user/.codex/config.toml /home/user/.config/opencode/opencode.json | sort -u)" = user ] || exit 16
curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null || exit 17
exit 0'
declare -A all_reason=(
  [10]="headroom does not answer /health"
  [11]="claude is not runnable as the user"
  [12]="codex is not runnable as the user"
  [13]="opencode is not runnable as the user"
  [14]="~/.codex/config.toml lacks the analytics opt-out"
  [15]="~/.config/opencode/opencode.json lacks the MCP server or autoupdate=false"
  [16]="the codex or opencode config is not owned by the user"
  [17]="the proxy died while the three harnesses ran (out of memory?)"
)
all_out=$(run_in_guest "$tmp" all "$all_script")
all_code=$(printf '%s' "$all_out" | sed -n 's/.*guest exit \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ "$all_code" = 0 ]; then
  pass "all tools: claude, codex and opencode run as the user, configs in place, proxy survives"
else
  bad "all-tools check failed: ${all_reason[${all_code:-x}]:-no guest exit code (boot or build failed, or the guest ran out of memory: SANDBOX_MEM=$mem MiB)}"
  echo "$all_out" | tail -6
fi

# Negative control: the same guest must fail a check that cannot pass, and the failure must come
# from the guest (a guest exit code), not from a broken boot. Otherwise a green run above could be
# vacuous (an exit code that never propagates looks identical).
ctl=$(run_in_guest "$flake" sandbox 'curl -fsS -m2 http://127.0.0.1:9/health')
if printf '%s' "$ctl" | grep -Eq 'guest exit [1-9]'; then
  pass "negative control fails inside the guest"
else
  bad "negative control fails inside the guest (no guest exit code)"
fi

exit $fail
