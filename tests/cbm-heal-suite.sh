#!/usr/bin/env bash
# Regression test for cbm-heal (modules/cbm-heal.sh): the watchdog that restarts a wedged
# codebase-memory-mcp daemon. A fake `codebase-memory-mcp` answers the initialize request with a canned
# line (or stays silent) and a fake `pkill` records its argv, so the heal decision is exercised
# without touching a real daemon. A wrong rule is silent either way: a missed wedge leaves every new
# session failing after 30s, a kill on any other error restarts a healthy daemon every poll.
# Runs in `nix flake check` (checks.<system>.cbm-heal); usage: cbm-heal-suite.sh <path to cbm-heal>.
set -u

script="${1:?usage: cbm-heal-suite.sh <path to cbm-heal>}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cbm-heal.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export CBM_HEAL_TIMEOUT=2
fail=0

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1: expected '$2', got '$3'"; fail=1; fi
}

cat >"$tmp/bin/codebase-memory-mcp" <<EOF
#!$BASH
read -r _
if [ "\${FAKE_SILENT:-0}" = 1 ]; then sleep 30; fi
printf '%s\n' "\$FAKE_REPLY"
EOF
cat >"$tmp/bin/pkill" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$tmp/pkill-calls"
EOF
chmod +x "$tmp/bin/codebase-memory-mcp" "$tmp/bin/pkill"

# run_heal <PATH>: sets rc, err and calls (the pkill argv lines).
run_heal() {
  : >"$tmp/pkill-calls"
  rc=0
  # Through $BASH, so an empty PATH (the not-installed case) cannot break the shebang lookup.
  PATH="$1" "$BASH" "$script" >"$tmp/out" 2>"$tmp/err" || rc=$?
  err="$(cat "$tmp/err")"
  calls="$(cat "$tmp/pkill-calls")"
}
with_binary="$tmp/bin:$PATH"

FAKE_REPLY='{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"codebase-memory-mcp"}}}' export FAKE_REPLY
run_heal "$with_binary"
assert_eq "healthy daemon: exit 0" 0 "$rc"
assert_eq "healthy daemon: nothing killed" "" "$calls"

export FAKE_REPLY='{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"CBM daemon is active or starting but could not accept this client within 30000 ms"}}'
run_heal "$with_binary"
assert_eq "wedged (-32001): exit 0" 0 "$rc"
# Anchored to the daemon's own argv, so a shell whose command line merely mentions the flag (a
# `zsh -c ...` wrapper) is never matched.
assert_eq "wedged (-32001): kills only the daemon process" \
  '-f ^[^ ]*codebase-memory-mcp --cbm-daemon-internal$' "$calls"

export FAKE_REPLY='{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"internal"}}'
run_heal "$with_binary"
assert_eq "other JSON-RPC error: exit 1" 1 "$rc"
assert_eq "other JSON-RPC error: nothing killed" "" "$calls"
case "$err" in *-32603*) echo "  ok: other JSON-RPC error: reported on stderr" ;; *) echo "  FAIL: stderr lacks -32603: $err"; fail=1 ;; esac

FAKE_SILENT=1 FAKE_REPLY=unused run_heal "$with_binary"
assert_eq "no answer within the timeout: exit 1" 1 "$rc"
assert_eq "no answer within the timeout: nothing killed" "" "$calls"
case "$err" in *"no reply"*) echo "  ok: no answer: reported on stderr" ;; *) echo "  FAIL: stderr lacks 'no reply': $err"; fail=1 ;; esac

# Not installed means nothing to heal: a silent success, because a launchd agent polls this.
mkdir "$tmp/empty"
run_heal "$tmp/empty"
assert_eq "not installed: exit 0" 0 "$rc"
assert_eq "not installed: nothing killed" "" "$calls"
assert_eq "not installed: silent" "" "$err"

exit "$fail"
