#!/usr/bin/env bash
# cbm-heal: restart a wedged codebase-memory-mcp daemon.
#
# The stdio client hands every session to one long-lived daemon (`--cbm-daemon-internal`). When that
# daemon wedges (days of uptime, no log output, sockets still open) the client waits 30s, then
# answers initialize with JSON-RPC error -32001 and Claude Code reports the MCP server as
# unreachable. The daemon never recovers on its own; killing it is the fix, the next client
# respawns it.
#
# Not installed means nothing to heal: exit 0 without a word, since the launchd agent runs this every
# 10 minutes. Otherwise probes with a real initialize request. Only -32001 triggers a kill. Any other
# outcome (other error, no reply) is reported on stderr and left alone.
#
# Env: CBM_HEAL_TIMEOUT  seconds to wait for the reply (default 40, above the client's own 30s)
# Exit: 0 healthy, healed or not installed, 1 probe failed for a reason other than a wedge
set -euo pipefail

command -v codebase-memory-mcp >/dev/null 2>&1 || exit 0

reply=$(
  python3 -I - "${CBM_HEAL_TIMEOUT:-40}" <<'PY'
import json, select, subprocess, sys

timeout = float(sys.argv[1])
try:
    p = subprocess.Popen(["codebase-memory-mcp"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
except OSError as e:
    print("spawn failed: %s" % e)
    sys.exit(0)
req = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
       "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                  "clientInfo": {"name": "cbm-heal", "version": "0"}}}
p.stdin.write((json.dumps(req) + "\n").encode())
p.stdin.flush()
ready, _, _ = select.select([p.stdout], [], [], timeout)
print(p.stdout.readline().decode().strip() if ready else "no reply within %ss" % timeout)
p.kill()
PY
)

case $reply in
  *'"code":-32001'*)
    echo "cbm-heal: daemon wedged (-32001); restarting it" >&2
    pkill -f '^[^ ]*codebase-memory-mcp --cbm-daemon-internal$' || true
    ;;
  *'"result"'*) ;;
  *)
    echo "cbm-heal: probe failed, daemon left alone: ${reply:-empty reply}" >&2
    exit 1
    ;;
esac
