#!/usr/bin/env bash
# Tests for t3-unlink-vm with a fake `t3` on a scratch PATH. Usage: t3-unlink-vm.sh <path to t3-unlink-vm>.
# The fake t3 serves `environment list --json` from $LIST and records every call in $LOG.
set -u
SUT="${1:?usage: t3-unlink-vm.sh <t3-unlink-vm>}"
BASH_BIN="$(command -v bash)"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

A='{"environmentId":"id-aaa","label":"personal","urls":["http://[fd7a:115c:a1e0::b]:3773"],"status":"reachable"}'
B='{"environmentId":"id-bbb","label":"personal","urls":["http://[fd7a:115c:a1e0::c]:3773"],"status":"unreachable"}'
C='{"environmentId":"id-ccc","label":"other","urls":["http://[fd7a:115c:a1e0::d]:3773"],"status":"reachable"}'

new_env() {
  TMP="$(mktemp -d)"
  LOG="$TMP/log"
  : > "$LOG"
  mkdir -p "$TMP/bin" "$TMP/base/userdata"
  cat > "$TMP/bin/t3" <<EOF2
#!$BASH_BIN
echo "t3 \$*" >> "$LOG"
case "\$1 \$2" in
  "--version "*) echo "t3 v\${FAKE_CLI_VERSION:-0.1.7}" ;;
  "environment list") [ -n "\${FAKE_LIST_FAIL:-}" ] && { echo "list broke" >&2; exit 4; }; printf '%s\n' "\$LIST" ;;
  "environment unlink") echo "Unlinked \$3" ;;
esac
EOF2
  chmod +x "$TMP/bin/t3"
  echo '{"serverVersion":"0.1.7"}' > "$TMP/base/userdata/server-runtime.json"
  export T3_BIN="$TMP/bin/t3" LOG TMP LIST="[$A,$B,$C]"
  unset FAKE_CLI_VERSION FAKE_LIST_FAIL
}

run() { "$SUT" --base-dir "$TMP/base" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
unlinked() { grep -c "environment unlink" "$LOG"; }

# 1. a unique label unlinks that environment, on the delegator's base dir
new_env
rc=$(run other)
[ "$rc" = 0 ] && ok "unlinks by label" || bad "unlinks by label (rc=$rc)"
grep -q "environment unlink id-ccc --base-dir $TMP/base" "$LOG" && ok "the matching id and base dir reach the CLI" || bad "the matching id and base dir reach the CLI"
grep -q "Unlinked id-ccc" "$TMP/out" && ok "the CLI output is shown" || bad "the CLI output is shown"

# 2. an id and a URL each match one environment
new_env
rc=$(run id-bbb)
grep -q "environment unlink id-bbb" "$LOG" && ok "unlinks by id" || bad "unlinks by id (rc=$rc)"
new_env
rc=$(run "http://[fd7a:115c:a1e0::b]:3773")
grep -q "environment unlink id-aaa" "$LOG" && ok "unlinks by URL" || bad "unlinks by URL (rc=$rc)"

# 3. a label shared by two environments is ambiguous: nothing is unlinked, both ids are named
new_env
rc=$(run personal)
[ "$rc" != 0 ] && ok "refuses an ambiguous label" || bad "refuses an ambiguous label"
[ "$(unlinked)" = 0 ] && ok "nothing is unlinked on an ambiguous label" || bad "nothing is unlinked on an ambiguous label"
grep -q "id-aaa" "$TMP/err" && grep -q "id-bbb" "$TMP/err" && ok "the error names both ids" || bad "the error names both ids"

# 4. no match
new_env
rc=$(run nothing)
[ "$rc" != 0 ] && ok "refuses a name that matches nothing" || bad "refuses a name that matches nothing"
[ "$(unlinked)" = 0 ] && ok "nothing is unlinked when nothing matches" || bad "nothing is unlinked when nothing matches"
new_env
export LIST='[]'
rc=$(run other)
[ "$rc" != 0 ] && ok "refuses when nothing is linked" || bad "refuses when nothing is linked"

# 5. a label is matched whole, never as a pattern or substring
new_env
rc=$(run 'oth.*')
[ "$rc" != 0 ] && [ "$(unlinked)" = 0 ] && ok "a pattern does not match" || bad "a pattern does not match"
new_env
rc=$(run othe)
[ "$rc" != 0 ] && [ "$(unlinked)" = 0 ] && ok "a substring does not match" || bad "a substring does not match"

# 6. the list command fails: no unlink
new_env
export FAKE_LIST_FAIL=1
rc=$(run other)
[ "$rc" != 0 ] && [ "$(unlinked)" = 0 ] && ok "fails when the list fails" || bad "fails when the list fails"

# 7. version rules as for t3-link-vm
new_env
export FAKE_CLI_VERSION=0.1.6
rc=$(run other)
[ "$rc" != 0 ] && ok "refuses a CLI that differs from the delegator" || bad "refuses a CLI that differs from the delegator"
grep -q "environment" "$LOG" && bad "nothing is listed or unlinked on a mismatch" || ok "nothing is listed or unlinked on a mismatch"
new_env
rm "$TMP/base/userdata/server-runtime.json"
rc=$(run other)
[ "$rc" != 0 ] && ok "refuses when the delegator has not started" || bad "refuses when the delegator has not started"
new_env
rm "$TMP/base/userdata/server-runtime.json"
rc=$(run --force other)
[ "$rc" = 0 ] && ok "--force goes on without a version to compare" || bad "--force goes on without a version to compare (rc=$rc)"
new_env
export FAKE_CLI_VERSION=0.1.6
rc=$(run --force other)
[ "$rc" != 0 ] && ok "--force does not override a mismatch" || bad "--force does not override a mismatch"

# 8. usage
new_env
rc=$("$SUT" >/dev/null 2>"$TMP/err"; echo $?)
[ "$rc" = 2 ] && ok "no arguments is a usage error (exit 2)" || bad "no arguments is a usage error (rc=$rc)"

# 9. the unlink command's failure is the script's failure
new_env
cat > "$TMP/bin/t3" <<EOF3
#!$BASH_BIN
case "\$1 \$2" in
  "--version "*) echo "t3 v0.1.7" ;;
  "environment list") printf '%s\n' "\$LIST" ;;
  "environment unlink") echo "unlink failed" >&2; exit 3 ;;
esac
EOF3
chmod +x "$TMP/bin/t3"
rc=$(run other)
[ "$rc" = 3 ] && ok "a failed unlink exits with the CLI's status" || bad "a failed unlink exits with the CLI's status (rc=$rc)"

exit $fail
