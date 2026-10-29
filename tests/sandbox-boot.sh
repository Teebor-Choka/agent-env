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

run_in_guest() { # script...: run it as the job in a fresh sandbox VM
  "$sandy" run --flake "path:$flake" --kind nixos-module --attr sandbox -- sh -c "$1" 2>&1
}

# Everything the sandbox promises, checked from inside one boot. sandy returns only the guest's exit
# code, so each check has its own code and the host names the failure from it.
guest_script='
for i in $(seq 60); do curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null && break; sleep 1; done
curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null || exit 10
command -v claude >/dev/null || exit 11
jq -e ".env.DISABLE_TELEMETRY == \"1\"" /etc/claude-code/managed-settings.json >/dev/null || exit 12
jq -e ".mcpServers[\"codebase-memory-mcp\"].alwaysLoad" /etc/claude-code/managed-mcp.json >/dev/null || exit 13
[ "$ANTHROPIC_BASE_URL" = http://127.0.0.1:8787 ] || exit 14
[ "$(systemctl show headroom-proxy -p DynamicUser --value)" = yes ] || exit 15
systemctl list-unit-files 2>/dev/null | grep -q home-manager && exit 16
exit 0'
declare -A reason=(
  [10]="headroom does not answer /health"
  [11]="claude is not on PATH"
  [12]="managed-settings.json lacks the telemetry opt-out"
  [13]="managed-mcp.json lacks the always-loaded MCP server"
  [14]="ANTHROPIC_BASE_URL is not routed to the proxy in the job environment"
  [15]="the proxy is not a DynamicUser service"
  [16]="home-manager is present in the sandbox"
)
out=$(run_in_guest "$guest_script")
code=$(printf '%s' "$out" | sed -n 's/.*guest exit \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ "$code" = 0 ]; then
  pass "sandbox boots, thin: headroom up as a DynamicUser, claude and its system config, no home-manager"
else
  bad "sandbox check failed: ${reason[${code:-x}]:-no guest exit code (boot or build failed)}"
  echo "$out" | tail -6
fi

# Negative control: the same guest must fail a check that cannot pass, and the failure must come
# from the guest (a guest exit code), not from a broken boot. Otherwise a green run above could be
# vacuous (an exit code that never propagates looks identical).
ctl=$(run_in_guest 'curl -fsS -m2 http://127.0.0.1:9/health')
if printf '%s' "$ctl" | grep -Eq 'guest exit [1-9]'; then
  pass "negative control fails inside the guest"
else
  bad "negative control fails inside the guest (no guest exit code)"
fi

exit $fail
