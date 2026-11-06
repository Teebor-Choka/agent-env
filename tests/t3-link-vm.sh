#!/usr/bin/env bash
# Tests for t3-link-vm with a fake `ssh` and a fake `t3` on a scratch PATH. Usage: t3-link-vm.sh <path to t3-link-vm>.
# Fakes record their arguments in $LOG; the fake t3 echoes the pairing code so redaction can be checked.
set -u
SUT="${1:?usage: t3-link-vm.sh <t3-link-vm>}"
# An absolute interpreter: the nix build sandbox has no /usr/bin/env.
BASH_BIN="$(command -v bash)"
CODE="CODE-s3cret-123"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

new_env() {
  TMP="$(mktemp -d)"
  LOG="$TMP/log"
  : > "$LOG"
  mkdir -p "$TMP/bin" "$TMP/base/userdata"
  cat > "$TMP/bin/t3" <<EOF
#!$BASH_BIN
echo "t3 \$*" >> "$LOG"
case "\$1" in
  --version) echo "t3 v\${FAKE_CLI_VERSION:-0.1.7}" ;;
  environment) echo "Linked personal (id) using \${FAKE_ECHO:-$CODE}" ;;
esac
EOF
  cat > "$TMP/bin/ssh" <<EOF
#!$BASH_BIN
echo "ssh \$*" >> "$LOG"
[ -n "\${FAKE_SSH_FAIL:-}" ] && exit 255
printf '%s\n' "\${FAKE_SSH_OUT-$CODE}"
EOF
  chmod +x "$TMP/bin/t3" "$TMP/bin/ssh"
  echo '{"serverVersion":"0.1.7"}' > "$TMP/base/userdata/server-runtime.json"
  export PATH="$TMP/bin:$PATH" T3_BIN="$TMP/bin/t3" LOG TMP
  unset FAKE_CLI_VERSION FAKE_SSH_FAIL FAKE_SSH_OUT FAKE_ECHO
}

run() { "$SUT" --base-dir "$TMP/base" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

# 1. matching versions: links with full access by default, code on the link command, never printed
new_env
rc=$(run vm1 "http://[fd7a:115c:a1e0::b]:3773")
[ "$rc" = 0 ] && ok "links when the CLI matches the delegator" || bad "links when the CLI matches the delegator (rc=$rc)"
grep -q -- "--access full-access" "$LOG" && ok "default access is full-access" || bad "default access is full-access"
grep -q -- "--pairing-code $CODE" "$LOG" && ok "the code reaches the link command" || bad "the code reaches the link command"
grep -q "environment link http://\[fd7a:115c:a1e0::b\]:3773" "$LOG" && ok "the URL is passed through" || bad "the URL is passed through"
grep -q -- "--base-dir $TMP/base" "$LOG" && ok "the delegator's base dir is used" || bad "the delegator's base dir is used"
if grep -q "$CODE" "$TMP/out" "$TMP/err"; then bad "the code is never printed"; else ok "the code is never printed"; fi
grep -q "<code>" "$TMP/out" && ok "the code is redacted in the CLI output" || bad "the code is redacted in the CLI output"
grep -q "ssh .*vm1 t3-pair" "$LOG" && ok "the code is minted on the guest with t3-pair" || bad "the code is minted on the guest with t3-pair"

# 2. version skew: refuse before touching the guest
new_env
export FAKE_CLI_VERSION=0.1.6
rc=$(run vm1 http://x:3773)
[ "$rc" != 0 ] && ok "refuses a CLI that differs from the delegator" || bad "refuses a CLI that differs from the delegator"
grep -q "0.1.6" "$TMP/err" && grep -q "0.1.7" "$TMP/err" && ok "the error names both versions" || bad "the error names both versions"
grep -q "^ssh " "$LOG" && bad "no code is minted on a version mismatch" || ok "no code is minted on a version mismatch"
grep -q "environment link" "$LOG" && bad "nothing is linked on a version mismatch" || ok "nothing is linked on a version mismatch"

# 3. the guest cannot be reached
new_env
export FAKE_SSH_FAIL=1
rc=$(run vm1 http://x:3773)
[ "$rc" != 0 ] && ok "fails when ssh fails" || bad "fails when ssh fails"
grep -q "environment link" "$LOG" && bad "nothing is linked when ssh fails" || ok "nothing is linked when ssh fails"

# 4. an empty code is an error
new_env
export FAKE_SSH_OUT=""
rc=$(run vm1 http://x:3773)
[ "$rc" != 0 ] && ok "fails on an empty code" || bad "fails on an empty code"
grep -q "environment link" "$LOG" && bad "nothing is linked on an empty code" || ok "nothing is linked on an empty code"

# 5. a chosen access mode is passed through
new_env
rc=$(run --access read-only vm1 http://x:3773)
grep -q -- "--access read-only" "$LOG" && ok "a chosen access mode is used" || bad "a chosen access mode is used"

# 6. no runtime file: the version cannot be compared, so it warns and goes on
new_env
rm "$TMP/base/userdata/server-runtime.json"
rc=$(run vm1 http://x:3773)
[ "$rc" = 0 ] && ok "links when the delegator has not started" || bad "links when the delegator has not started (rc=$rc)"
grep -qi "cannot compare\|not running\|no runtime" "$TMP/err" && ok "it warns that the version was not compared" || bad "it warns that the version was not compared"

# 7. missing arguments are a usage error
new_env
rc=$("$SUT" >/dev/null 2>"$TMP/err"; echo $?)
[ "$rc" = 2 ] && ok "no arguments is a usage error (exit 2)" || bad "no arguments is a usage error (rc=$rc)"

# 8. a code with characters that are special to sed is still redacted
new_env
export FAKE_SSH_OUT='a/b&c.d' FAKE_ECHO='a/b&c.d'
rc=$(run vm1 http://x:3773)
[ "$rc" = 0 ] && ok "links with an unusual code" || bad "links with an unusual code (rc=$rc)"
if grep -qF 'a/b&c.d' "$TMP/out" "$TMP/err"; then bad "an unusual code is never printed"; else ok "an unusual code is never printed"; fi
grep -q "<code>" "$TMP/out" && ok "an unusual code is redacted" || bad "an unusual code is redacted"

# 9. an ssh target that looks like an option is not read as one
new_env

new_env
rc=$("$SUT" --base-dir "$TMP/base" -- -oProxyCommand=evil http://x:3773 >"$TMP/out" 2>"$TMP/err"; echo $?)
grep -q "^ssh -- -oProxyCommand=evil t3-pair" "$LOG" && ok "an option-like target comes after --" || bad "an option-like target comes after --"

# 10. the link command's failure is the script's failure
new_env
cat > "$TMP/bin/t3" <<EOF2
#!$BASH_BIN
case "\$1" in --version) echo "t3 v0.1.7" ;; environment) echo "link failed" >&2; exit 3 ;; esac
EOF2
chmod +x "$TMP/bin/t3"
rc=$(run vm1 http://x:3773)
[ "$rc" = 3 ] && ok "a failed link exits with the link command's status" || bad "a failed link exits with the link command's status (rc=$rc)"

exit $fail
