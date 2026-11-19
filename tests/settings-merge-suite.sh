#!/usr/bin/env bash
# Tests for modules/home/claude-settings-merge.sh: merge declared settings over a live settings.json.
#   settings-merge-suite.sh <merge-script>
# Runs under the bash that runs it and, when present and different, under /bin/bash (3.2 on macOS).
set -euo pipefail
mrg=$1
fail=0
work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

shells="$BASH"
if [ -x /bin/bash ] && ! [ /bin/bash -ef "$BASH" ]; then shells="$shells /bin/bash"; fi

check() { # label want got
  echo "$1" >>"$work/labels"
  if [ "$2" = "$3" ]; then echo "ok   $tag $1"; else echo "FAIL $tag $1: expected $2, got $3"; fail=1; fi
}
smode() { if stat -c %a / >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
j() { jq -c "$1" "$work/d/settings.json"; }
fresh() { rm -rf "$work/d" "$work/decl.json" "$work/hooks.json"; mkdir "$work/d"; }
runargs() { set +e; "$sh" "$mrg" "$@" >"$work/out" 2>&1; rc=$?; set -e; out=$(<"$work/out"); }
run() { runargs --declared "$work/decl.json" "$@" "$work/d/settings.json"; }

suite() {
tag="[$("$sh" -c 'echo ${BASH_VERSION%%(*}')]"
: >"$work/labels"
S="$work/d/settings.json"

fresh; echo '{"model":"opus","env":{"A":"1"}}' >"$work/decl.json"; run
check "a missing file is created" 0 "$rc"
check "the created file holds the declared keys" '{"model":"opus","env":{"A":"1"}}' "$(j .)"

fresh; echo '{"theme":"dark","extra":{"k":1}}' >"$S"; echo '{"model":"opus"}' >"$work/decl.json"; run
check "an undeclared key survives" '{"theme":"dark","extra":{"k":1},"model":"opus"}' "$(j .)"

fresh; echo '{"model":"sonnet","env":{"OLD":"x","A":"0"}}' >"$S"; echo '{"model":"opus","env":{"A":"1"}}' >"$work/decl.json"; run
check "a declared key overrides the live value" '"opus"' "$(j .model)"
check "a declared object replaces the live object, not a deep merge" '{"A":"1"}' "$(j .env)"

fresh; echo '{"theme":"dark","a":[1,2]}' >"$S"; echo '{"model":"opus","env":{"A":"1"}}' >"$work/decl.json"; run
cp "$S" "$work/first"; touch -t 200001010000 "$S"; run
check "a second run is byte-identical" 0 "$(cmp -s "$work/first" "$S" && echo 0 || echo 1)"
touch -t 200001010000 "$S"; before=$(stat -c %Y "$S" 2>/dev/null || stat -f %m "$S"); run
check "an unchanged result leaves the mtime alone" "$before" "$(stat -c %Y "$S" 2>/dev/null || stat -f %m "$S")"

fresh; echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"old"}]}]}}' >"$S"
echo '{}' >"$work/decl.json"
echo '{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"new"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"end"}]}]}' >"$work/hooks.json"
run --hooks "$work/hooks.json"
check "a rendered event replaces the live event" '"new"' "$(j '.hooks.PreToolUse[0].hooks[0].command')"
check "a live event the render lacks survives" '"keep"' "$(j '.hooks.Stop[0].hooks[0].command')"
check "a new rendered event is added" '"end"' "$(j '.hooks.SessionEnd[0].hooks[0].command')"
cp "$S" "$work/first"; run --hooks "$work/hooks.json"
check "the hooks merge is idempotent" 0 "$(cmp -s "$work/first" "$S" && echo 0 || echo 1)"

fresh; echo '{"model":"sonnet","hooks":{"Stop":[1]}}' >"$S"; echo '{"hooks":{"Stop":[]}}' >"$work/decl.json"; run
check "declared hooks merge by event too, other keys survive" '{"model":"sonnet","hooks":{"Stop":[]}}' "$(j .)"

fresh; printf '{"a":' >"$S"; echo '{"model":"opus"}' >"$work/decl.json"; run
check "a corrupt file does not fail the run" 0 "$rc"
check "the corrupt file is moved aside" '{"a":' "$(cat "$S.bak-1")"
check "a fresh file replaces it" '{"model":"opus"}' "$(j .)"
printf 'junk' >"$S"; run
check "a second corrupt file takes the next number" 'junk' "$(cat "$S.bak-2")"
check "the first backup is kept" '{"a":' "$(cat "$S.bak-1")"

fresh; echo '[1]' >"$S"; echo '{"model":"opus"}' >"$work/decl.json"; run
check "a JSON file that is not an object counts as corrupt" '[1]' "$(cat "$S.bak-1")"
fresh; : >"$S"; echo '{"model":"opus"}' >"$work/decl.json"; run
check "an empty file counts as corrupt" 0 "$([ -e "$S.bak-1" ] && echo 0 || echo 1)"

# a read-only store symlink becomes a real, writable file; the link target stays as it was
fresh; echo '{"theme":"dark"}' >"$work/store.json"; chmod 444 "$work/store.json"; ln -s "$work/store.json" "$S"
echo '{"model":"opus"}' >"$work/decl.json"; run
check "a symlinked settings.json is replaced by a real file" 0 "$([ -L "$S" ] && echo 1 || echo 0)"
check "the live content is kept through the link" '{"theme":"dark","model":"opus"}' "$(j .)"
check "the link target is untouched" '{"theme":"dark"}' "$(jq -c . "$work/store.json")"
check "the new file is writable" 0 "$([ -w "$S" ] && echo 0 || echo 1)"
chmod 644 "$work/store.json"

fresh; echo '{"a":1}' >"$S"; chmod 600 "$S"; echo '{"model":"opus"}' >"$work/decl.json"; run
check "the file mode survives a rewrite" 600 "$(smode "$S")"

# secret and state files are never opened, and never targeted
fresh; echo '{"a":1}' >"$S"; echo '{"model":"opus"}' >"$work/decl.json"
for f in .credentials.json daemon-auth-status.json remote-settings.json policy-limits.json; do
  echo SECRET >"$work/d/$f"
done
mkdir "$work/d/session-env"; echo SECRET >"$work/d/session-env/x"
if [ "$(id -u)" = 0 ]; then
  echo "skip $tag unreadable secrets: running as root"
else
  chmod 000 "$work/d/.credentials.json" "$work/d/daemon-auth-status.json" "$work/d/remote-settings.json" "$work/d/policy-limits.json" "$work/d/session-env"
  run
  check "unreadable secret files do not stop the run" 0 "$rc"
  chmod 700 "$work/d/session-env"; chmod 600 "$work/d/.credentials.json" "$work/d/daemon-auth-status.json" "$work/d/remote-settings.json" "$work/d/policy-limits.json"
fi
check "the secret files are unchanged" "SECRET" "$(cat "$work/d/.credentials.json" "$work/d/remote-settings.json" | sort -u)"
check "only settings.json and its siblings exist after the run" ".credentials.json daemon-auth-status.json policy-limits.json remote-settings.json session-env settings.json" "$(cd "$work/d" && ls -A | tr '\n' ' ' | sed 's/ $//')"
for t in .credentials.json daemon-auth-status.json daemon-auth-cooldown remote-settings.json remote-settings.json.signature.json policy-limits.json settings.local.json; do
  runargs --declared "$work/decl.json" "$work/d/$t"
  check "refuses to target $t" 2 "$rc"
done
check "a refused target is not written" "SECRET" "$(cat "$work/d/.credentials.json")"

# arguments and inputs
fresh; echo '{"a":1}' >"$S"; echo '[1]' >"$work/decl.json"; run
check "declared settings that are not an object fail" 2 "$rc"
check "the live file is untouched after a bad declared file" '{"a":1}' "$(j .)"
fresh; echo '{"a":1}' >"$S"; runargs --declared "$work/none.json" "$S"
check "a missing declared file fails" 2 "$rc"
runargs "$S"
check "no --declared fails" 2 "$rc"
runargs
check "no arguments fail" 2 "$rc"
fresh; echo '{"a":1}' >"$S"; echo '{}' >"$work/decl.json"; runargs --declared "$work/decl.json" --hooks "$work/none.json" "$S"
check "a missing hooks file fails" 2 "$rc"
echo '[1]' >"$work/hooks.json"; runargs --declared "$work/decl.json" --hooks "$work/hooks.json" "$S"
check "hooks that are not an object fail" 2 "$rc"
fresh; echo '{}' >"$work/decl.json"; runargs --declared "$work/decl.json" "$work/nodir/settings.json"
check "a target in a missing directory fails" 2 "$rc"

# values never reach the output
fresh; echo '{"env":{"T":"TOKEN-OLD-1"}}' >"$S"; echo '{"env":{"T":"TOKEN-NEW-2"}}' >"$work/decl.json"; run
if grep -qE 'TOKEN-' <<<"$out"; then echo "FAIL $tag a settings value was printed: $out"; fail=1; else echo "ok   $tag a settings value is never printed"; fi
check "the run prints which keys it declared" "settings-merge: wrote $S (declared: env)" "$out"

dups=$(sort "$work/labels" | uniq -d)
if [ -n "$dups" ]; then echo "FAIL $tag duplicate test labels: $dups"; fail=1; else echo "ok   $tag every test label is unique"; fi
}

for sh in $shells; do suite; done
exit $fail
