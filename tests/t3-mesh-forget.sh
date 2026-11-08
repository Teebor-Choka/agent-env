#!/usr/bin/env bash
# Tests for t3-mesh-forget with a fake admin command. Usage: t3-mesh-forget.sh <path to t3-mesh-forget>.
# The fake admin serves `headscale nodes list -o json` from $NODES and records every call in $LOG; a
# `headscale nodes delete -i N --force` removes node N from $NODES unless FAKE_KEEP is set.
set -u
SUT="${1:?usage: t3-mesh-forget.sh <t3-mesh-forget>}"
BASH_BIN="$(command -v bash)"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

new_env() {
  TMP="$(mktemp -d)"
  LOG="$TMP/log"
  NODES="$TMP/nodes.json"
  : > "$LOG"
  cat > "$NODES" <<'JSON'
[
  {"id":6,"name":"ws01","given_name":"ws01","tags":null,"online":false},
  {"id":18,"name":"linux-h","given_name":"linux-h","tags":["tag:t3"],"online":false},
  {"id":19,"name":"bp","given_name":"bp","tags":["tag:t3"],"online":true},
  {"id":20,"name":"linux-h","given_name":"linux-h-1","tags":["tag:t3"],"online":false},
  {"id":21,"name":"twin","given_name":"twin","tags":["tag:t3"],"online":false},
  {"id":22,"name":"twin","given_name":"twin","tags":["tag:t3"],"online":null},
  {"id":2,"name":"dns","given_name":"dns","tags":["tag:server"],"online":false}
]
JSON
  cat > "$TMP/admin" <<EOF2
#!$BASH_BIN
echo "admin \$*" >> "$LOG"
case "\$*" in
  "headscale nodes list -o json")
    [ -n "\${FAKE_LIST_FAIL:-}" ] && { echo "list broke" >&2; exit 4; }
    n=\$(cat "$TMP/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/n"
    if [ -n "\${FAKE_FLIP:-}" ] && [ "\$n" -ge 2 ]; then
      jq 'map(if .id == 18 then .online = true else . end)' "$NODES"
    else
      cat "$NODES"
    fi ;;
  "headscale nodes delete -i "*)
    id="\$5"
    if [ -z "\${FAKE_KEEP:-}" ]; then
      jq --argjson id "\$id" 'map(select(.id != \$id))' "$NODES" > "$NODES.new" && mv "$NODES.new" "$NODES"
    fi
    echo "Node deleted" ;;
esac
EOF2
  chmod +x "$TMP/admin"
  export T3_MESH_ADMIN="$TMP/admin" LOG NODES
  unset FAKE_KEEP FAKE_LIST_FAIL FAKE_FLIP
}

run() { "$SUT" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }
deletes() { grep -c "nodes delete" "$LOG"; }

# 1. without --yes nothing is deleted and the match is shown
new_env
rc=$(run linux-h)
[ "$rc" = 0 ] && ok "dry run succeeds" || bad "dry run succeeds (rc=$rc)"
[ "$(deletes)" = 0 ] && ok "dry run deletes nothing" || bad "dry run deletes nothing"
grep -q "would delete id 18" "$TMP/out" && ok "dry run names the id" || bad "dry run names the id"

# 2. --yes deletes by the numeric id only, with --force, and confirms the node is gone
new_env
rc=$(run --yes linux-h)
[ "$rc" = 0 ] && ok "deletes with --yes" || bad "deletes with --yes (rc=$rc)"
grep -q "^admin headscale nodes delete -i 18 --force$" "$LOG" && ok "the delete call carries the numeric id and --force" || bad "the delete call carries the numeric id and --force"
[ "$(deletes)" = 1 ] && ok "exactly one delete" || bad "exactly one delete"
jq -e 'map(.id) | index(18) | not' "$NODES" >/dev/null && ok "the node is gone afterwards" || bad "the node is gone afterwards"
jq -e 'map(.id) | index(20) != null' "$NODES" >/dev/null && ok "a suffixed twin is untouched" || bad "a suffixed twin is untouched"

# 3. an online node is refused
new_env
rc=$(run --yes bp)
[ "$rc" != 0 ] && ok "online node refused" || bad "online node refused"
[ "$(deletes)" = 0 ] && ok "online node not deleted" || bad "online node not deleted"
grep -qi "online" "$TMP/err" && ok "the refusal says why" || bad "the refusal says why"

# 3b. a dry run on an online node is refused too
new_env
rc=$(run bp)
[ "$rc" != 0 ] && ok "online node refused in a dry run" || bad "online node refused in a dry run (rc=$rc)"

# 3c. a node that comes online between the first look and the delete is refused
new_env
export FAKE_FLIP=1
rc=$(run --yes linux-h)
[ "$rc" != 0 ] && [ "$(deletes)" = 0 ] && ok "a node that came online is not deleted" || bad "a node that came online is not deleted (rc=$rc)"

# 4. a node without the tag is refused, whatever its name
new_env
rc=$(run --yes ws01)
[ "$rc" != 0 ] && [ "$(deletes)" = 0 ] && ok "untagged node refused" || bad "untagged node refused (rc=$rc)"
new_env
rc=$(run --yes dns)
[ "$rc" != 0 ] && [ "$(deletes)" = 0 ] && ok "a node with another tag is refused" || bad "a node with another tag is refused (rc=$rc)"
new_env
rc=$(run --yes --tag tag:server dns)
[ "$rc" = 0 ] && [ "$(deletes)" = 1 ] && ok "--tag selects another tag" || bad "--tag selects another tag (rc=$rc)"

# 5. several matches are refused and listed
new_env
rc=$(run --yes twin)
[ "$rc" != 0 ] && [ "$(deletes)" = 0 ] && ok "two matches refused" || bad "two matches refused (rc=$rc)"
grep -q "21" "$TMP/err" && grep -q "22" "$TMP/err" && ok "both ids are listed" || bad "both ids are listed"

# 6. no match is an error
new_env
rc=$(run --yes ghost)
[ "$rc" != 0 ] && [ "$(deletes)" = 0 ] && ok "no match is an error" || bad "no match is an error (rc=$rc)"

# 7. a hostname that is not a DNS label is refused before any admin call
for h in 'a;b' 'a b' '$(id)' 'LINUX-H' '-x' ''; do
  new_env
  rc=$(run --yes "$h")
  [ "$rc" != 0 ] && [ ! -s "$LOG" ] && ok "refuses hostname '$h'" || bad "refuses hostname '$h' (rc=$rc)"
done

# 8. a node that is still listed after the delete is an error
new_env
export FAKE_KEEP=1
rc=$(run --yes linux-h)
[ "$rc" != 0 ] && ok "a node that stays is an error" || bad "a node that stays is an error"

# 9. a failing list is an error and deletes nothing
new_env
export FAKE_LIST_FAIL=1
rc=$(run --yes linux-h)
[ "$rc" != 0 ] && [ "$(deletes)" = 0 ] && ok "a failing list is an error" || bad "a failing list is an error (rc=$rc)"

# 10. no admin command configured is an error
new_env
unset T3_MESH_ADMIN
rc=$(run --yes linux-h)
[ "$rc" != 0 ] && grep -q "T3_MESH_ADMIN" "$TMP/err" && ok "missing T3_MESH_ADMIN is an error" || bad "missing T3_MESH_ADMIN is an error (rc=$rc)"

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
