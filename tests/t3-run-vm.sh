#!/usr/bin/env bash
# Tests for t3-run-vm with a fake `ssh` (the VM host) and a fake `t3` (the app's CLI). Usage: t3-run-vm.sh <t3-run-vm>
# The fake ssh answers the wrapper's remote commands from files in $TMP, runs a busybox httpd as the local
# end of the tunnel, and records every call in $LOG. The fake t3 keeps the linked environments in $TMP/envs.
# The guest's unit is active from the start script's run until `systemctl stop` or $TMP/unit.stopped.
set -u
SUT="${1:?usage: t3-run-vm.sh <t3-run-vm>}"
BASH_BIN="$(command -v bash)"
BB="$(command -v busybox)"
CODE="CODE-s3cret-123"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

new_env() {
  TMP="$(mktemp -d)"
  LOG="$TMP/log"
  : > "$LOG"
  mkdir -p "$TMP/bin" "$TMP/base/userdata" "$TMP/state" "$TMP/www" "$TMP/scripts"
  echo '<html>t3</html>' > "$TMP/www/index.html"
  echo '[]' > "$TMP/envs"
  : > "$TMP/scripts/start.sh"; : > "$TMP/scripts/guest.sh"
  cat > "$TMP/bin/t3" <<EOF
#!$BASH_BIN
echo "t3 \$*" >> "$LOG"
case "\$1 \$2" in
  "--version "*) echo "t3 v\${FAKE_CLI_VERSION:-0.1.7}" ;;
  "environment link") [ -n "\${FAKE_LINK_FAIL:-}" ] && { echo "link refused" >&2; exit 1; }
    echo "Linked guest (env-1) using \$5"
    printf '[{"environmentId":"env-1","label":"guest","urls":["%s"],"status":"reachable"}]\n' "\$3" > "$TMP/envs" ;;
  "environment list") cat "$TMP/envs" ;;
  "environment unlink") [ -n "\${FAKE_UNLINK_FAIL:-}" ] && { echo "unlink broke" >&2; exit 4; }
    echo '[]' > "$TMP/envs"; echo "Unlinked \$3" ;;
esac
EOF
  cat > "$TMP/bin/ssh" <<EOF
#!$BASH_BIN
echo "ssh \$*" >> "$LOG"
[ -f "$TMP/hostdown" ] && exit 255 # the host is unreachable while this file exists
tty=0; tunnel=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -t) tty=1; shift ;; -N) shift ;; -o) shift 2 ;; -L) tunnel="\$2"; shift 2 ;; --) shift; break ;; *) break ;;
  esac
done
shift # the host
cmd="\$*"
if [ -n "\$tunnel" ]; then
  port="\${tunnel#127.0.0.1:}"; port="\${port%%:*}"
  exec "$BB" httpd -f -p "\$port" -h "$TMP/www"
fi
case "\$cmd" in
  *"mkdir -p"*) cat > /dev/null; exit 0 ;;
  *start.sh*) touch "$TMP/started"; exit \${FAKE_START_RC:-0} ;;
  *curl*) [ -n "\${FAKE_NO_CODE:-}" ] && exit 0; echo "192.168.84.5 $CODE"; exit 0 ;;
  *"systemctl is-active"*) if [ -f "$TMP/started" ] && [ ! -f "$TMP/unit.stopped" ]; then echo active; else echo inactive; fi; exit 0 ;;
  *"systemctl stop"*) touch "$TMP/unit.stopped"; exit 0 ;;
  *"rm -rf"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/t3" "$TMP/bin/ssh"
  echo '{"serverVersion":"0.1.7"}' > "$TMP/base/userdata/server-runtime.json"
  export T3_RUN_VM_POLL=1 PATH="$TMP/bin:$PATH" T3_BIN="$TMP/bin/t3" XDG_STATE_HOME="$TMP/state" LOG TMP
  unset FAKE_CLI_VERSION FAKE_UNLINK_FAIL FAKE_START_RC FAKE_NO_CODE FAKE_LINK_FAIL T3_RUN_VM_RECHECK
}

COMMON=(--host ws01 --guest 192.168.84.5)
run() { "$SUT" "${COMMON[@]}" --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 20 "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
# end the guest after N seconds, as the host would
end_guest_after() { ( "$BB" sleep "$1"; touch "$TMP/unit.stopped" ) & }
start_linked() { # sets pid; waits until the entry is linked and the state file is written
  "$SUT" "${COMMON[@]}" --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 20 >"$TMP/out" 2>"$TMP/err" &
  pid=$!
  for _ in $(seq 100); do [ -f "$TMP/state/t3-run-vm/env-1" ] && break; "$BB" sleep 0.2; done
}
unlinked() { grep -q "environment unlink env-1" "$LOG"; }
stopped_with_sudo() { grep -q "ssh -t .*-- ws01 sudo systemctl stop t3vm-" "$LOG"; }
seed() { # envId status [unit line]: an entry in the app and a state file for it
  mkdir -p "$TMP/state/t3-run-vm"
  printf '%s\n' "${3-unit=t3vm-abc}" > "$TMP/state/t3-run-vm/$1"
  printf '[{"environmentId":"%s","label":"guest","urls":["http://localhost:1"],"status":"%s"}]\n' "$1" "$2" > "$TMP/envs"
}

# 1. the whole life: start, code, tunnel, link, hold until the unit stops, unlink
new_env
end_guest_after 3
rc=$(run --start-env FOO=bar)
[ "$rc" = 0 ] && ok "a guest that ends on its own exits 0" || { bad "a guest that ends on its own exits 0 (rc=$rc)"; cat "$TMP/err"; }
grep -q "ssh -t .*-- ws01 UNIT=t3vm-.* NONCE=[0-9a-f]\{32\} JOB_TIMEOUT=604800 FOO=bar bash .*start.sh" "$LOG" && ok "start.sh runs with a terminal, a nonce and the extra environment" || bad "start.sh runs with a terminal, a nonce and the extra environment"
grep -q "environment link http://localhost:[0-9]* --pairing-code $CODE --access full-access --base-dir $TMP/base" "$LOG" && ok "links the tunnel URL with the code, full access by default" || bad "links the tunnel URL with the code, full access by default"
unlinked && ok "unlinks the environment when the guest stops" || bad "unlinks the environment when the guest stops"
grep -q "systemctl stop" "$LOG" && bad "no stop for a unit that has ended" || ok "no stop for a unit that has ended"
if grep -q "$CODE" "$TMP/out" "$TMP/err"; then bad "the code is never printed"; else ok "the code is never printed"; fi
[ -z "$(ls "$TMP/state/t3-run-vm" 2>/dev/null)" ] && ok "no state is left after a clean unlink" || bad "no state is left after a clean unlink"
echo '[]' | cmp -s - "$TMP/envs" && ok "nothing stays linked" || bad "nothing stays linked"
grep -q "ssh .*uploads\|cat > .cache/t3-run-vm/.*/start.sh" "$LOG" && ok "the start script is uploaded" || bad "the start script is uploaded"

# 2. SIGTERM: the unit is stopped with sudo, the entry unlinked, the state file written meanwhile
new_env
start_linked
grep -q '^unit=t3vm-' "$TMP/state/t3-run-vm/env-1" && grep -q '^linkedAt=' "$TMP/state/t3-run-vm/env-1" && ok "the state file records the unit and linkedAt" || bad "the state file records the unit and linkedAt"
kill -TERM "$pid"
wait "$pid"; rc=$?
[ "$rc" = 143 ] && ok "a signalled wrapper exits 143" || bad "a signalled wrapper exits 143 (rc=$rc)"
stopped_with_sudo && ok "a signal stops the unit with sudo" || bad "a signal stops the unit with sudo"
unlinked && ok "a signal unlinks" || bad "a signal unlinks"

# 2b. SIGHUP
new_env
start_linked
kill -HUP "$pid"
wait "$pid"; rc=$?
[ "$rc" = 143 ] && unlinked && ok "SIGHUP unlinks and exits 143" || bad "SIGHUP unlinks and exits 143 (rc=$rc)"

# 3. the link fails while the unit runs: the unit is stopped, exit 1
new_env
export FAKE_LINK_FAIL=1
rc=$(run)
[ "$rc" = 1 ] && ok "a failed link exits 1" || bad "a failed link exits 1 (rc=$rc)"
stopped_with_sudo && [ -f "$TMP/unit.stopped" ] && ok "a failed link stops the running unit" || bad "a failed link stops the running unit"

# 3b. the stop does not work: exit 1, and it says so
new_env
export FAKE_LINK_FAIL=1
sed -i 's|\*"systemctl stop"\*) touch "\$TMP/unit.stopped"; exit 0 ;;|*"systemctl stop"*) exit 1 ;;|;s|  \*"systemctl stop"\*) touch "[^"]*"; exit 0 ;;|  *"systemctl stop"*) exit 1 ;;|' "$TMP/bin/ssh"
rc=$(run)
{ [ "$rc" = 1 ] && grep -q "may still run" "$TMP/err"; } && ok "a unit that cannot be stopped exits 1 and says so" || bad "a unit that cannot be stopped exits 1 and says so (rc=$rc)"

# 4. an unlink that fails: non-zero exit, state kept for the next run
new_env
export FAKE_UNLINK_FAIL=1
end_guest_after 3
rc=$(run)
[ "$rc" = 1 ] && ok "a failed unlink exits 1" || bad "a failed unlink exits 1 (rc=$rc)"
[ -f "$TMP/state/t3-run-vm/env-1" ] && ok "the state stays for the next run" || bad "the state stays for the next run"

# 5. the reaper: unreachable with a stopped unit is unlinked; reachable, running or without a unit is not
new_env; seed env-9 unreachable
rc=$(run --reap-only)
{ [ "$rc" = 0 ] && grep -q "environment unlink env-9" "$LOG" && [ ! -f "$TMP/state/t3-run-vm/env-9" ]; } && ok "unlinks an unreachable entry whose unit stopped" || bad "unlinks an unreachable entry whose unit stopped (rc=$rc)"
new_env; seed env-9 unreachable; touch "$TMP/started"
rc=$(run --reap-only)
{ [ "$rc" = 0 ] && ! grep -q "environment unlink" "$LOG" && ! grep -q "systemctl stop" "$LOG"; } && ok "a running guest keeps its entry and is not stopped" || bad "a running guest keeps its entry and is not stopped (rc=$rc)"
new_env; seed env-9 reachable
rc=$(run --reap-only)
grep -q "environment unlink" "$LOG" && bad "keeps a reachable entry" || ok "keeps a reachable entry"
new_env; seed env-9 unreachable "job=x"
rc=$(run --reap-only)
{ ! grep -q "environment unlink" "$LOG" && [ -f "$TMP/state/t3-run-vm/env-9" ]; } && ok "an entry with no recorded unit is left linked" || bad "an entry with no recorded unit is left linked"
new_env; mkdir -p "$TMP/state/t3-run-vm"; echo unit=t3vm-abc > "$TMP/state/t3-run-vm/env-9"
rc=$(run --reap-only)
[ ! -f "$TMP/state/t3-run-vm/env-9" ] && ok "drops state for an entry the app no longer lists" || bad "drops state for an entry the app no longer lists"
new_env; seed env-9 unreachable; export FAKE_UNLINK_FAIL=1
rc=$(run --reap-only)
[ "$rc" = 1 ] && ok "a failed reaper unlink exits 1" || bad "a failed reaper unlink exits 1 (rc=$rc)"
new_env; seed env-9 unreachable
rc=$(run --reap-only); : > "$LOG"
rc=$(run --reap-only)
{ [ "$rc" = 0 ] && ! grep -q "environment unlink" "$LOG"; } && ok "a second reaper run does nothing" || bad "a second reaper run does nothing (rc=$rc)"

# 6. an entry the tool did not create is never touched, even with the host down
new_env
printf '[{"environmentId":"personal-1","label":"personal","urls":["http://[fd7a::b]:3773"],"status":"unreachable"}]\n' > "$TMP/envs"
touch "$TMP/hostdown"
rc=$(run --reap-only)
grep -q "environment unlink" "$LOG" && bad "leaves entries without a state file alone" || ok "leaves entries without a state file alone"

# 7. the host is unreachable when the wrapper is signalled: the unlink still runs, at once; exit 1
new_env
start_linked
touch "$TMP/hostdown"
t0=$SECONDS
kill -TERM "$pid"
wait "$pid"; rc=$?
[ "$rc" = 1 ] && unlinked && ok "a dead host does not stop the unlink; exit 1" || bad "a dead host does not stop the unlink; exit 1 (rc=$rc)"
[ $((SECONDS - t0)) -lt 25 ] && ok "a dead host does not hold the exit up" || bad "a dead host does not hold the exit up"
[ ! -f "$TMP/state/t3-run-vm/env-1" ] && ok "the state file goes with the unlink" || bad "the state file goes with the unlink"

# 8. the tunnel drops: the entry is unlinked and the unit stopped; exit 1
new_env
start_linked
"$BB" pkill -f "httpd -f -p [0-9]* -h $TMP/www" 2>/dev/null
wait "$pid"; rc=$?
[ "$rc" = 1 ] && unlinked && stopped_with_sudo && ok "a dropped tunnel unlinks and stops the unit" || bad "a dropped tunnel unlinks and stops the unit (rc=$rc)"

# 9. kill -9 leaves the entry; the reaper unlinks it once the app lists it unreachable and the unit has stopped
new_env
start_linked
kill -KILL "$pid"; wait "$pid" 2>/dev/null
"$BB" pkill -f "httpd -f -p [0-9]* -h $TMP/www" 2>/dev/null
[ -f "$TMP/state/t3-run-vm/env-1" ] && ok "kill -9 leaves the state file" || bad "kill -9 leaves the state file"
sed -i 's/"reachable"/"unreachable"/' "$TMP/envs"
touch "$TMP/unit.stopped"
rc=$(run --reap-only)
{ [ "$rc" = 0 ] && unlinked && [ ! -f "$TMP/state/t3-run-vm/env-1" ]; } && ok "the reaper unlinks after kill -9" || bad "the reaper unlinks after kill -9 (rc=$rc)"

# 10. the host is unreachable: two unreachable checks, a re-check interval apart, before the unlink
new_env; seed env-9 unreachable; export T3_RUN_VM_RECHECK=3; touch "$TMP/hostdown"
rc=$(run --reap-only)
{ [ "$rc" = 0 ] && ! grep -q "environment unlink" "$LOG" && grep -q '^unreachableSince=' "$TMP/state/t3-run-vm/env-9"; } && ok "the first unreachable check keeps the entry and records the time" || bad "the first unreachable check keeps the entry and records the time (rc=$rc)"
rc=$(run --reap-only)
grep -q "environment unlink" "$LOG" && bad "a second check inside the interval keeps the entry" || ok "a second check inside the interval keeps the entry"
"$BB" sleep 4
rc=$(run --reap-only)
{ [ "$rc" = 0 ] && grep -q "environment unlink env-9" "$LOG"; } && ok "a second check after the interval unlinks" || bad "a second check after the interval unlinks (rc=$rc)"
new_env; seed env-9 reachable "$(printf 'unit=t3vm-abc\nunreachableSince=1')"; export T3_RUN_VM_RECHECK=3; touch "$TMP/hostdown"
rc=$(run --reap-only)
{ ! grep -q "environment unlink" "$LOG" && ! grep -q unreachableSince "$TMP/state/t3-run-vm/env-9"; } && ok "a reachable entry clears the unreachable time" || bad "a reachable entry clears the unreachable time"

# 11. an entry that is already gone is a clean exit with no unlink call
new_env
start_linked
echo '[]' > "$TMP/envs"
kill -TERM "$pid"
wait "$pid"; rc=$?
{ [ "$rc" = 143 ] && ! grep -q "environment unlink" "$LOG" && [ ! -f "$TMP/state/t3-run-vm/env-1" ]; } && ok "an entry the user already unlinked is a clean exit" || bad "an entry the user already unlinked is a clean exit (rc=$rc)"

# 12. version skew is refused before the host is touched
new_env
export FAKE_CLI_VERSION=0.1.6
rc=$(run)
[ "$rc" != 0 ] && ok "refuses a CLI that differs from the app" || bad "refuses a CLI that differs from the app"
grep -q "^ssh " "$LOG" && bad "no ssh on a version mismatch" || ok "no ssh on a version mismatch"

# 13. the start step fails: nothing is linked, non-zero exit
new_env
export FAKE_START_RC=1
rc=$(run)
[ "$rc" != 0 ] && ok "a failed start exits non-zero" || bad "a failed start exits non-zero"
grep -q "environment link" "$LOG" && bad "nothing is linked after a failed start" || ok "nothing is linked after a failed start"

# 14. no code from the guest: gives up, nothing is linked, the unit is stopped
new_env
export FAKE_NO_CODE=1
rc=$("$SUT" "${COMMON[@]}" --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 4 >"$TMP/out" 2>"$TMP/err"; echo $?)
[ "$rc" != 0 ] && ok "gives up when the guest never publishes a code" || bad "gives up when the guest never publishes a code"
grep -q "environment link" "$LOG" && bad "nothing is linked without a code" || ok "nothing is linked without a code"
stopped_with_sudo && ok "the unit is stopped when the start-up gives up" || bad "the unit is stopped when the start-up gives up"

# 15. --guest probes one address; --bridge probes the host's neighbours on that bridge
new_env
end_guest_after 2
rc=$(run)
grep -q "ip -4 neigh" "$LOG" && bad "--guest does not look at neighbours" || ok "--guest does not look at neighbours"
new_env
end_guest_after 2
rc=$("$SUT" --host ws01 --bridge br7 --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 20 >"$TMP/out" 2>"$TMP/err"; echo $?)
grep -q "ip -4 neigh show dev br7" "$LOG" && [ "$rc" = 0 ] && ok "--bridge probes the neighbours on that bridge" || bad "--bridge probes the neighbours on that bridge (rc=$rc)"

# 16. usage errors exit 2 and touch nothing
usage_rc() { new_env; rc=$("$SUT" "$@" >/dev/null 2>&1; echo $?); }
usage_rc --bogus;                                                       [ "$rc" = 2 ] && ok "an unknown option is a usage error" || bad "an unknown option is a usage error (rc=$rc)"
usage_rc --guest 1.2.3.4 --start-script "$TMP/scripts";                 [ "$rc" = 2 ] && ok "--host is required" || bad "--host is required (rc=$rc)"
usage_rc --host ws01 --guest 1.2.3.4;                                   [ "$rc" = 2 ] && ok "--start-script is required" || bad "--start-script is required (rc=$rc)"
new_env; rc=$("$SUT" --host ws01 --start-script "$TMP/scripts" >/dev/null 2>&1; echo $?); [ "$rc" = 2 ] && ok "--guest or --bridge is required" || bad "--guest or --bridge is required (rc=$rc)"
new_env; rm "$TMP/scripts/start.sh"; rc=$(run); [ "$rc" = 2 ] && ok "a script directory without start.sh is refused" || bad "a script directory without start.sh is refused (rc=$rc)"
new_env; rc=$(run --host 'a;touch /tmp/x'); [ "$rc" = 2 ] && ok "a host with shell characters is refused" || bad "a host with shell characters is refused (rc=$rc)"
new_env; rc=$(run --start-env 'X=a b'); [ "$rc" = 2 ] && ok "a start environment with a space is refused" || bad "a start environment with a space is refused (rc=$rc)"
new_env; grep -q "^ssh " "$LOG" && bad "no ssh on a usage error" || ok "no ssh on a usage error"
new_env; end_guest_after 2; rc=$(run --start-script "$TMP/scripts/start.sh"); [ "$rc" = 0 ] && ok "--start-script accepts the path of start.sh" || bad "--start-script accepts the path of start.sh (rc=$rc)"
new_env; rc=$("$SUT" --host ws01 --base-dir "$TMP/base" --reap-only >/dev/null 2>&1; echo $?); [ "$rc" = 0 ] && ok "--reap-only needs only --host" || bad "--reap-only needs only --host (rc=$rc)"

exit $fail
