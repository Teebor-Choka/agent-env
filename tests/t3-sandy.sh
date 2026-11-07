#!/usr/bin/env bash
# Tests for t3-sandy with a fake `ssh` (the sandy host) and a fake `t3` (the app's CLI). Usage: t3-sandy.sh <t3-sandy>
# The fake ssh answers the wrapper's remote commands from files in $TMP, runs a busybox httpd as the local
# end of the tunnel, and records every call in $LOG. The fake t3 keeps the linked environments in $TMP/envs.
set -u
SUT="${1:?usage: t3-sandy.sh <t3-sandy>}"
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
  : > "$TMP/scripts/start.sh"; : > "$TMP/scripts/guest.sh"
  echo '<html>t3</html>' > "$TMP/www/index.html"
  echo '[]' > "$TMP/envs"
  cat > "$TMP/bin/t3" <<EOF
#!$BASH_BIN
echo "t3 \$*" >> "$LOG"
case "\$1 \$2" in
  "--version "*) echo "t3 v\${FAKE_CLI_VERSION:-0.1.7}" ;;
  "environment link") [ -n "\${FAKE_LINK_FAIL:-}" ] && { touch "$TMP/ended.newjob"; echo "link refused" >&2; exit 1; }
    echo "Linked sandy (env-1) using \$5"
    printf '[{"environmentId":"env-1","label":"sandy","urls":["%s"],"status":"reachable"}]\n' "\$3" > "$TMP/envs" ;;
  "environment list") cat "$TMP/envs" ;;
  "environment unlink") [ -n "\${FAKE_UNLINK_FAIL:-}" ] && { echo "unlink broke" >&2; exit 4; }
    echo '[]' > "$TMP/envs"; echo "Unlinked \$3" ;;
esac
EOF
  cat > "$TMP/bin/ssh" <<EOF
#!$BASH_BIN
echo "ssh \$*" >> "$LOG"
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
job=\$(printf '%s' "\$cmd" | sed -n 's|.*/jobs/\([A-Za-z0-9-]*\)\.json.*|\1|p')
case "\$cmd" in
  *trust-roots*) echo "\${FAKE_TRUST:-ok}"; exit 0 ;;
  *"ls ~/.sandy/jobs"*) echo old.json; [ -f "$TMP/started" ] && echo newjob.json; exit 0 ;;
  *"mkdir -p"*) cat > /dev/null; exit 0 ;;
  *start.sh*) touch "$TMP/started"; exit \${FAKE_START_RC:-0} ;;
  *"ip -4 neigh"*) [ -n "\${FAKE_NO_CODE:-}" ] && exit 0; echo "192.168.84.5 $CODE"; exit 0 ;;
  *"systemctl is-active"*) # the unit runs from the start until stopped; the record alone does not end it
    if [ ! -f "$TMP/started" ] || [ -f "$TMP/unit.stopped" ]; then echo inactive
    elif [ -f "$TMP/ended.newjob" ] && [ -z "\${FAKE_UNIT_STAYS:-}" ]; then echo inactive
    else echo active; fi; exit 0 ;;
  *"jq -r"*"/jobs/"*) [ -f "$TMP/ended.\$job" ] && echo yes || echo no; exit 0 ;;
  *"sandy kill"*) touch "$TMP/ended.newjob"; exit 0 ;; # as the unprivileged user: a record, not a stop
  *"systemctl stop"*) touch "$TMP/unit.stopped" "$TMP/ended.newjob"; exit 0 ;;
  *"rm -rf"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/t3" "$TMP/bin/ssh"
  echo '{"serverVersion":"0.1.7"}' > "$TMP/base/userdata/server-runtime.json"
  export T3_SANDY_POLL=1 PATH="$TMP/bin:$PATH" T3_BIN="$TMP/bin/t3" XDG_STATE_HOME="$TMP/state" LOG TMP
  unset FAKE_CLI_VERSION FAKE_UNLINK_FAIL FAKE_START_RC FAKE_NO_CODE FAKE_UNIT_STAYS FAKE_LINK_FAIL FAKE_TRUST
}

run() { "$SUT" --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 20 "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
calls() { grep -c -- "$1" "$LOG"; }
# end the job after N seconds, as the sandy host would
end_job_after() { ( "$BB" sleep "$1"; touch "$TMP/ended.newjob" ) & }

# 1. the whole life: start, code, tunnel, link, hold until the job ends, unlink
new_env
end_job_after 3
rc=$(run)
[ "$rc" = 0 ] && ok "a job that ends on its own exits 0" || { bad "a job that ends on its own exits 0 (rc=$rc)"; cat "$TMP/err"; }
grep -q "ssh -t -- ws01 UNIT=sandbox-.* NONCE=[0-9a-f]\{32\} .*start.sh" "$LOG" && ok "start.sh runs with a terminal and a nonce" || bad "start.sh runs with a terminal and a nonce"
grep -q "environment link http://localhost:[0-9]* --pairing-code $CODE --access full-access --base-dir $TMP/base" "$LOG" && ok "links the tunnel URL with the code, full access by default" || bad "links the tunnel URL with the code, full access by default"
grep -q "environment unlink env-1" "$LOG" && ok "unlinks the environment when the job ends" || bad "unlinks the environment when the job ends"
if grep -q "$CODE" "$TMP/out" "$TMP/err"; then bad "the code is never printed"; else ok "the code is never printed"; fi
[ -z "$(ls "$TMP/state/t3-sandy" 2>/dev/null)" ] && ok "no state is left after a clean unlink" || bad "no state is left after a clean unlink"
echo '[]' | cmp -s - "$TMP/envs" && ok "nothing stays linked" || bad "nothing stays linked"

# 2. a signal stops the job and unlinks
new_env
"$SUT" --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 20 >"$TMP/out" 2>"$TMP/err" &
pid=$!
for _ in $(seq 100); do grep -q "environment link" "$LOG" && break; "$BB" sleep 0.2; done
"$BB" sleep 1
kill -TERM "$pid"
wait "$pid"; rc=$?
[ "$rc" = 143 ] && ok "a signalled wrapper exits 143" || bad "a signalled wrapper exits 143 (rc=$rc)"
grep -q "ssh -t -- ws01 sudo systemctl stop sandbox-" "$LOG" && ok "a signal stops the unit with sudo" || bad "a signal stops the unit with sudo"
grep -q "sandy kill" "$LOG" && bad "sandy kill is not used" || ok "sandy kill is not used"
grep -q "environment unlink env-1" "$LOG" && ok "a signal unlinks" || bad "a signal unlinks"

# 3. the link fails after the record got a result, but the unit still runs: it is stopped anyway, exit 1
new_env
export FAKE_LINK_FAIL=1 FAKE_UNIT_STAYS=1
rc=$(run)
[ "$rc" = 1 ] && ok "a failed link exits 1" || bad "a failed link exits 1 (rc=$rc)"
grep -q "ssh -t -- ws01 sudo systemctl stop sandbox-" "$LOG" && ok "a running unit is stopped whatever the record says" || bad "a running unit is stopped whatever the record says"
[ -f "$TMP/unit.stopped" ] && ok "the unit is stopped" || bad "the unit is stopped"

# 3b. a job that ended on its own needs no stop and no sudo prompt
new_env
end_job_after 2
rc=$(run)
grep -q "systemctl stop" "$LOG" && bad "no stop for a unit that has ended" || ok "no stop for a unit that has ended"

# 4. an unlink that fails: non-zero exit, state kept for the next run
new_env
export FAKE_UNLINK_FAIL=1
end_job_after 3
rc=$(run)
[ "$rc" = 1 ] && ok "a failed unlink exits 1" || bad "a failed unlink exits 1 (rc=$rc)"
[ -f "$TMP/state/t3-sandy/env-1" ] && ok "the state stays for the next run" || bad "the state stays for the next run"

# 5. the backstop: unreachable and ended is unlinked; reachable, or unreachable with a running job, is not
backstop() { # status, job ended (yes/no), [unlink fails] -> sets rc; not run in a subshell, so $TMP and $LOG stay
  new_env
  mkdir -p "$TMP/state/t3-sandy"
  echo job-9 > "$TMP/state/t3-sandy/env-9"
  printf '[{"environmentId":"env-9","label":"sandy","urls":["http://localhost:1"],"status":"%s"}]\n' "$1" > "$TMP/envs"
  [ "$2" = yes ] && touch "$TMP/ended.job-9"
  [ -z "${3:-}" ] || export FAKE_UNLINK_FAIL=1
  rc=$(run --reap-only)
}
backstop unreachable yes
[ "$rc" = 0 ] && grep -q "environment unlink env-9" "$LOG" && [ ! -f "$TMP/state/t3-sandy/env-9" ] && ok "unlinks an unreachable entry whose job ended" || bad "unlinks an unreachable entry whose job ended (rc=$rc)"
backstop unreachable no
grep -q "environment unlink" "$LOG" && bad "keeps an unreachable entry whose job still runs" || ok "keeps an unreachable entry whose job still runs"
backstop reachable yes
grep -q "environment unlink" "$LOG" && bad "keeps a reachable entry" || ok "keeps a reachable entry"
new_env
mkdir -p "$TMP/state/t3-sandy"; echo job-9 > "$TMP/state/t3-sandy/env-9"
rc=$(run --reap-only)
[ ! -f "$TMP/state/t3-sandy/env-9" ] && ok "drops state for an entry the app no longer lists" || bad "drops state for an entry the app no longer lists"
backstop unreachable yes fail
[ "$rc" = 1 ] && ok "a failed backstop unlink exits 1" || bad "a failed backstop unlink exits 1 (rc=$rc)"

# 6. never touches an entry it did not create
new_env
mkdir -p "$TMP/state/t3-sandy"
printf '[{"environmentId":"personal-1","label":"personal","urls":["http://[fd7a::b]:3773"],"status":"unreachable"}]\n' > "$TMP/envs"
rc=$(run --reap-only)
grep -q "environment unlink" "$LOG" && bad "leaves entries without t3-sandy state alone" || ok "leaves entries without t3-sandy state alone"

# 7. version skew is refused before the sandy host is touched
new_env
export FAKE_CLI_VERSION=0.1.6
rc=$(run)
[ "$rc" != 0 ] && ok "refuses a CLI that differs from the app" || bad "refuses a CLI that differs from the app"
grep -q "^ssh " "$LOG" && bad "no ssh on a version mismatch" || ok "no ssh on a version mismatch"

# 8. the start step fails: nothing is linked, non-zero exit
new_env
export FAKE_START_RC=1
rc=$(run)
[ "$rc" != 0 ] && ok "a failed start exits non-zero" || bad "a failed start exits non-zero"
grep -q "environment link" "$LOG" && bad "nothing is linked after a failed start" || ok "nothing is linked after a failed start"

# 9. no code from the guest: gives up, nothing is linked, the job is stopped
new_env
export FAKE_NO_CODE=1
rc=$("$SUT" --base-dir "$TMP/base" --start-script "$TMP/scripts" --ready-timeout 4 >"$TMP/out" 2>"$TMP/err"; echo $?)
[ "$rc" != 0 ] && ok "gives up when the guest never publishes a code" || bad "gives up when the guest never publishes a code"
grep -q "environment link" "$LOG" && bad "nothing is linked without a code" || ok "nothing is linked without a code"
grep -q "ssh -t -- ws01 sudo systemctl stop sandbox-" "$LOG" && ok "the unit is stopped when the start-up gives up" || bad "the unit is stopped when the start-up gives up"

# 10. the trust-root preflight runs before the sandy host is changed
new_env
export FAKE_TRUST="bad /home/u/.config/sandy/trust-roots"
rc=$(run)
[ "$rc" = 1 ] && ok "a trust root that is not root's stops the run" || bad "a trust root that is not root's stops the run (rc=$rc)"
grep -q "ssh -t -- ws01 sudo chown -R root:root" "$LOG" && bad "the fix is printed, not run" || ok "the fix is printed, not run"
grep -q "sudo chown -R root:root ~/.config/sandy/trust-roots && sudo chmod -R go-rwx" "$TMP/err" && ok "prints the exact fix command" || bad "prints the exact fix command"
grep -q "start.sh" "$LOG" && bad "nothing is uploaded or started after a failed preflight" || ok "nothing is uploaded or started after a failed preflight"
new_env
export FAKE_TRUST=missing
rc=$(run)
[ "$rc" = 1 ] && grep -q "no ~/.config/sandy/trust-roots" "$TMP/err" && ok "a missing trust root stops the run" || bad "a missing trust root stops the run (rc=$rc)"
new_env
export FAKE_TRUST=missing
end_job_after 3
rc=$(run --no-preflight)
[ "$rc" = 0 ] && ok "--no-preflight skips the check" || bad "--no-preflight skips the check (rc=$rc)"

# 11. --start-script: a directory or start.sh itself; both files are required
new_env
end_job_after 3
rc=$(run --start-script "$TMP/scripts/start.sh")
[ "$rc" = 0 ] && ok "--start-script accepts the path of start.sh" || bad "--start-script accepts the path of start.sh (rc=$rc)"
new_env
rc=$("$SUT" --base-dir "$TMP/base" >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && ok "a start without --start-script is a usage error (exit 2)" || bad "a start without --start-script is a usage error (rc=$rc)"
new_env
rm "$TMP/scripts/guest.sh"
rc=$(run)
[ "$rc" = 2 ] && ok "a script directory without guest.sh is refused" || bad "a script directory without guest.sh is refused (rc=$rc)"
grep -q "^ssh " "$LOG" && bad "no ssh when a script file is missing" || ok "no ssh when a script file is missing"
new_env
rc=$(run --reap-only)
[ "$rc" = 0 ] && ok "--reap-only needs no --start-script" || bad "--reap-only needs no --start-script (rc=$rc)"

# 12. an unknown option is a usage error
new_env
rc=$("$SUT" --bogus >/dev/null 2>&1; echo $?)
[ "$rc" = 2 ] && ok "an unknown option is a usage error (exit 2)" || bad "an unknown option is a usage error (rc=$rc)"

exit $fail
