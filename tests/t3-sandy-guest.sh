#!/usr/bin/env bash
# Tests for sandy/guest.sh with fake `runuser`, `t3` and `sandy-t3-ready` and a real busybox httpd.
# Usage: t3-sandy-guest.sh <guest.sh>. Needs busybox and curl on PATH.
set -u
SUT="${1:?usage: t3-sandy-guest.sh <guest.sh>}"
BASH_BIN="$(command -v bash)"
BB="$(command -v busybox)"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

new_env() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin" "$TMP/home"
  # runuser -u USER -- CMD...: run CMD as is
  cat > "$TMP/bin/runuser" <<EOF
#!$BASH_BIN
shift 3
exec "\$@"
EOF
  cat > "$TMP/bin/t3" <<EOF
#!$BASH_BIN
case "\$1 \$2" in
  "serve "*) echo serving >> "$TMP/serve.log"; exec "$BB" sleep 600 ;;
  "auth pairing") [ -n "\${FAKE_NO_AUTH:-}" ] && exit 1; printf 'Issued client pairing token abc.\nToken: %s\nExpires at: soon\n' "\${FAKE_CODE:-TOKEN-1234567}" ;;
  "pair "*|"pair") printf '%s\n' "\${FAKE_PAIR_OUT:-OLDCODE1234}" ;;
esac
EOF
  cat > "$TMP/bin/sandy-t3-ready" <<EOF
#!$BASH_BIN
[ -f "$TMP/serve.log" ]
EOF
  chmod +x "$TMP/bin/runuser" "$TMP/bin/t3" "$TMP/bin/sandy-t3-ready"
  export PATH="$TMP/bin:$PATH" T3_HOME="$TMP/home" T3_USER="$(id -un)" T3_NONCE=0123456789abcdef \
    T3_BUSYBOX="$BB" T3_CODE_DIR="$TMP/www" T3_CODE_PORT=$((30000 + RANDOM % 20000)) T3_PORT=1
  unset FAKE_NO_AUTH FAKE_CODE FAKE_PAIR_OUT
}

start() { "$BASH_BIN" "$SUT" >"$TMP/out" 2>"$TMP/err" & pid=$!; }
stop() { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; "$BB" pkill -f "httpd -f -p $T3_CODE_PORT" 2>/dev/null; return 0; }
fetch() { curl -s -o "$TMP/body" -w '%{http_code}' --max-time 2 "http://127.0.0.1:$T3_CODE_PORT/$1" 2>/dev/null; }
wait_code() { for _ in $(seq 50); do [ "$(fetch "$T3_NONCE")" = 200 ] && return 0; "$BB" sleep 0.2; done; return 1; }

# 1. seeds the config, starts the server, publishes the code at /<nonce> only
new_env
start
wait_code && ok "the code is published at /<nonce>" || bad "the code is published at /<nonce>"
grep -qx "TOKEN-1234567" "$TMP/body" && ok "the body is the minted code" || bad "the body is the minted code"
[ "$(fetch other)" = 404 ] && ok "any other path is a 404" || bad "any other path is a 404"
[ "$(fetch "")" != 200 ] && ok "the directory itself is not served" || bad "the directory itself is not served"
grep -q linkedEnvironmentsEnabled "$TMP/home/.t3/userdata/settings.json" && ok "linked environments are seeded on" || bad "linked environments are seeded on"
grep -q hasCompletedOnboarding "$TMP/home/.claude.json" && ok "the harness onboarding is seeded" || bad "the harness onboarding is seeded"
[ -f "$TMP/serve.log" ] && ok "t3 serve was started" || bad "t3 serve was started"
stop

# 2. a settings file that exists is kept
new_env
mkdir -p "$TMP/home/.t3/userdata"
echo '{"mine":true}' > "$TMP/home/.t3/userdata/settings.json"
start; wait_code; stop
grep -q '"mine":true' "$TMP/home/.t3/userdata/settings.json" && ok "an existing settings file is kept" || bad "an existing settings file is kept"

# 3. an older build with only `t3 pair`
new_env
export FAKE_NO_AUTH=1
start
wait_code && grep -qx "OLDCODE1234" "$TMP/body" && ok "falls back to t3 pair" || bad "falls back to t3 pair"
stop

# 4. no code can be minted: the job fails with a message, nothing is published
new_env
export FAKE_NO_AUTH=1 FAKE_PAIR_OUT="not a token at all"
"$BASH_BIN" "$SUT" >"$TMP/out" 2>"$TMP/err"; rc=$?
[ "$rc" != 0 ] && ok "fails when no code can be minted" || bad "fails when no code can be minted"
grep -q "could not mint a pairing code" "$TMP/err" && ok "says why" || bad "says why"
[ ! -e "$TMP/www/$T3_NONCE" ] && ok "nothing is published without a code" || bad "nothing is published without a code"

# 5. a bad nonce is refused before anything starts
new_env
export T3_NONCE='../etc'
"$BASH_BIN" "$SUT" >"$TMP/out" 2>"$TMP/err"; rc=$?
[ "$rc" = 2 ] && [ ! -f "$TMP/serve.log" ] && ok "a nonce that is not lowercase hex is refused" || bad "a nonce that is not lowercase hex is refused (rc=$rc)"

# 6. no nonce at all
new_env
unset T3_NONCE
"$BASH_BIN" "$SUT" >"$TMP/out" 2>"$TMP/err"; rc=$?
[ "$rc" != 0 ] && ok "a missing nonce is refused" || bad "a missing nonce is refused"

exit $fail
