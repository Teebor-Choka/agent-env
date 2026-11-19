#!/usr/bin/env bash
# Tests for modules/home/claude-config-compare.sh: a rendered config dir vs a live ~/.claude.
#   config-compare-suite.sh <compare-script> <classes.json> <fixture-dir>
# The whole suite runs under the bash that runs it and, when present and different, under /bin/bash
# (3.2 on macOS), the shell the script must also work in.
set -euo pipefail
cmp=$1 classes=$2 fix=$3
fail=0
work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
real_jq=$(command -v jq)

shells="$BASH"
if [ -x /bin/bash ] && ! [ /bin/bash -ef "$BASH" ]; then shells="$shells /bin/bash"; fi

check() { # label want got
  echo "$1" >>"$work/labels"
  if [ "$2" = "$3" ]; then echo "ok   $tag $1"; else echo "FAIL $tag $1: expected $2, got $3"; fail=1; fi
}
# the whole line, not a substring that any line may hold
has_line() { # label line output
  echo "$1" >>"$work/labels"
  if grep -qxF -- "$2" <<<"$3"; then echo "ok   $tag $1"; else echo "FAIL $tag $1: no line '$2' in: $3"; fail=1; fi
}
no_line() { # label line output
  echo "$1" >>"$work/labels"
  if grep -qxF -- "$2" <<<"$3"; then echo "FAIL $tag $1: unexpected line '$2' in: $3"; fail=1; else echo "ok   $tag $1"; fi
}
smode() { if stat -c %a / >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
fresh() { rm -rf "$work/r" "$work/l" "$work/r-store" "$work/l-store" "$work/r-skills" "$work/l-skills"; cp -R "$fix/render" "$work/r"; cp -R "$fix/live" "$work/l"; chmod -R u+w "$work/r" "$work/l"; }
runargs() { set +e; "$sh" "$cmp" --classes "$classes" "$@" >"$work/out" 2>&1; rc=$?; set -e; out=$(<"$work/out"); }
run() { runargs "$work/r" "$work/l"; }

# plugin-dirs entries are symlinks to directories (store paths): walk the trees they point at.
linkdirs() { mkdir -p "$work/$1/plugin-dirs" "$work/$1-store/p"; echo "${2:-same}" >"$work/$1-store/p/f"; ln -s "$work/$1-store/p" "$work/$1/plugin-dirs/p"; }
# skills is a link to a tree (the neutral skills dir): walked like a dir
linktree() { mkdir -p "$work/$1-skills/a"; echo "${2:-same}" >"$work/$1-skills/a/f"; ln -s "$work/$1-skills" "$work/$1/skills"; }
realskills() { mkdir -p "$work/$1/skills/a"; echo "${2:-same}" >"$work/$1/skills/a/f"; }

suite() {
tag="[$("$sh" -c 'echo ${BASH_VERSION%%(*}')]"
: >"$work/labels"

fresh; run; check "identical generated config, live-only state and secrets ignored" 0 "$rc"

fresh; echo extra >"$work/l/hooks/g"; run
check "a generated file that differs fails" 1 "$rc"; has_line "names the file" "DIFF differs: hooks/g" "$out"

fresh; rm "$work/l/agents/r.md"; run
check "a generated file missing from live fails" 1 "$rc"; has_line "names the missing file" "DIFF missing in live: agents/r.md" "$out"

fresh; echo x >"$work/r/agents/new.md"; run
check "a rendered file missing from live fails" 1 "$rc"; has_line "names the new rendered file" "DIFF missing in live: agents/new.md" "$out"

fresh; echo x >"$work/l/agents/stray.md"; run
check "a live-only file in a generated dir fails" 1 "$rc"; has_line "names the stray file" "DIFF only in live: agents/stray.md" "$out"

fresh; jq '.model="opus"' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a declared settings key that differs fails" 1 "$rc"; has_line "names the differing key" "DIFF settings.json: model: differs" "$out"

fresh; jq 'del(.theme)' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a declared settings key missing from live fails" 1 "$rc"; has_line "says the key is absent" "DIFF settings.json: theme: absent in live" "$out"

fresh; jq '.extraLive=1' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a live-only settings key is merged state, not a diff" 0 "$rc"

fresh; echo s >"$work/r/.credentials.json"; run
check "a secret in the render fails" 1 "$rc"; has_line "names the render secret" "DIFF secret in the render: .credentials.json" "$out"

fresh; echo x >"$work/l/brand-new-thing"; run
check "an unclassified live top-level entry fails" 1 "$rc"; has_line "names the live entry" "DIFF unclassified top-level entry: brand-new-thing" "$out"

fresh; echo x >"$work/r/brand-new-thing"; run
check "an unclassified rendered top-level entry fails" 1 "$rc"; has_line "names the rendered entry" "DIFF unclassified top-level entry: brand-new-thing" "$out"

fresh; mkdir "$work/l/projects" && echo x >"$work/l/projects/p"; run
check "runtime state in live is ignored" 0 "$rc"

fresh; linkdirs r; linkdirs l; run
check "equal symlinked plugin dirs compare equal" 0 "$rc"
fresh; linkdirs r; linkdirs l other; run
check "differing symlinked plugin dirs fail" 1 "$rc"; has_line "names the file in the linked tree" "DIFF differs: plugin-dirs/p/f" "$out"
fresh; linkdirs r; linkdirs l; echo x >"$work/r-store/p/g"; run
check "a file only in the rendered linked tree fails" 1 "$rc"; has_line "names the rendered-only file" "DIFF missing in live: plugin-dirs/p/g" "$out"
fresh; linkdirs r; linkdirs l; echo x >"$work/l-store/p/g"; run
check "a file only in the live linked tree fails" 1 "$rc"; has_line "names the live-only file" "DIFF only in live: plugin-dirs/p/g" "$out"
# B4: a secret name inside a linked tree
fresh; linkdirs r; linkdirs l; echo s >"$work/r-store/p/.credentials.json"; echo s >"$work/l-store/p/.credentials.json"; run
check "a secret name inside a linked tree fails" 1 "$rc"; has_line "names the secret in the tree" "DIFF secret in the render: plugin-dirs/p/.credentials.json" "$out"
# B5: modes inside a linked tree
fresh; linkdirs r; linkdirs l; chmod +x "$work/r-store/p/f"; run
check "an executable bit that differs inside a linked tree fails" 1 "$rc"; has_line "names the file with the mode" "DIFF mode differs: plugin-dirs/p/f" "$out"
# a link cycle must fail, not hang
fresh; linkdirs r; linkdirs l; ln -s .. "$work/r-store/p/loop"; run
check "a symlink loop inside a linked tree fails" 1 "$rc"; has_line "names the looping tree" "DIFF cannot walk (loop, deeper than 64 or unreadable): plugin-dirs/p" "$out"
rm -rf "$work/r-store" "$work/l-store"

# --- review round: exit 0 although a difference exists ---
fresh; chmod +x "$work/r/hooks/g" "$work/l/hooks/g"; chmod -x "$work/l/hooks/g"; run
check "an executable bit that differs fails" 1 "$rc"; has_line "says mode" "DIFF mode differs: hooks/g" "$out"

# B6: the bits come from stat, not from `[ -x ]` for whoever runs the check
fresh; chmod 610 "$work/r/hooks/g"; chmod 600 "$work/l/hooks/g"; run
check "an execute bit held only by the group is compared" 1 "$rc"; has_line "says mode for the group bit" "DIFF mode differs: hooks/g" "$out"
fresh; chmod 755 "$work/r/hooks/g"; chmod 700 "$work/l/hooks/g"; run
check "other permission bits do not count as a mode difference" 0 "$rc"

fresh; touch "$work/l/..stash"; run
check "a top-level name starting with .. is classified" 1 "$rc"; has_line "names the dotted entry" "DIFF unclassified top-level entry: ..stash" "$out"

fresh; mkdir -p "$work/l/$(printf 'projects\nanything')"; run
check "a newline in a name cannot borrow another name's class" 1 "$rc"

fresh; rm -rf "$work/r/agents" "$work/l/agents"; echo a >"$work/r/agents"; echo b >"$work/l/agents"; run
check "a generated dir that is a file on both sides is compared" 1 "$rc"; has_line "names the agents file" "DIFF differs: agents" "$out"

fresh; mkdir "$work/r/agents/sub"; run
check "an empty dir only in the render fails" 1 "$rc"; has_line "names the render-only dir" "DIFF missing in live: agents/sub" "$out"

fresh; mkdir "$work/l/agents/sub"; run
check "an empty dir only in live fails" 1 "$rc"; has_line "names the live-only dir" "DIFF only in live: agents/sub" "$out"

fresh; echo '{bad' >"$work/r/settings.json"; run
check "an invalid render settings.json fails, not skipped" 1 "$rc"; has_line "says why the render is invalid" "DIFF settings.json: render is not a JSON object" "$out"

fresh; echo '[1]' >"$work/r/settings.json"; run
check "a non-object render settings.json fails" 1 "$rc"

fresh; echo '{bad' >"$work/l/settings.json"; run
check "an invalid live settings.json exits 1 with a message" 1 "$rc"; has_line "says why the live is invalid" "DIFF settings.json: live is not a JSON object" "$out"

fresh; ln -s /nonexistent "$work/r/.credentials.json"; run
check "a dangling secret symlink in the render fails" 1 "$rc"; has_line "is a secret finding for the link" "DIFF secret in the render: .credentials.json" "$out"

fresh; echo s >"$work/r/hooks/.credentials.json"; echo s >"$work/l/hooks/.credentials.json"; run
check "a secret name inside a generated dir fails" 1 "$rc"; has_line "is a secret finding for the hooks file" "DIFF secret in the render: hooks/.credentials.json" "$out"

fresh; echo secret >"$work/r/.credentials.json"; run
no_line "a secret in the render is not reported as unclassified" "DIFF unclassified top-level entry: .credentials.json" "$out"

fresh; echo c >"$work/r/CLAUDE.md"; echo d >"$work/l/CLAUDE.md"; run
check "a generated top-level file that differs fails" 1 "$rc"; has_line "names CLAUDE.md" "DIFF differs: CLAUDE.md" "$out"

fresh; ln -s /nonexistent "$work/r/CLAUDE.md"; ln -s /nonexistent "$work/l/CLAUDE.md"; run
check "a dangling generated file fails even when both sides dangle" 1 "$rc"; has_line "names the dangling file" "DIFF dangling: CLAUDE.md" "$out"

fresh; linktree r; linktree l; run
check "equal skills trees compare equal" 0 "$rc"
fresh; linktree r; linktree l other; run
check "differing skills trees fail" 1 "$rc"; has_line "names the skills file" "DIFF differs: skills/a/f" "$out"
fresh; linktree r; run
check "a skills link missing from live fails" 1 "$rc"; has_line "names the missing link" "DIFF missing in live: skills" "$out"
has_line "lists the files under the missing link" "DIFF missing in live: skills/a/f" "$out"
rm -rf "$work/r-skills" "$work/l-skills"

# B1: a link name that is a real dir on both sides is walked like a generated dir
fresh; realskills r; realskills l; run
check "equal real skills dirs compare equal" 0 "$rc"
fresh; realskills r; realskills l other; run
check "differing real skills dirs fail" 1 "$rc"; has_line "names the real skills file" "DIFF differs: skills/a/f" "$out"
fresh; realskills r; realskills l; echo x >"$work/l/skills/a/g"; run
check "a live-only file in a real skills dir fails" 1 "$rc"; has_line "names the live-only skills file" "DIFF only in live: skills/a/g" "$out"
fresh; realskills r; realskills l; chmod +x "$work/r/skills/a/f"; run
check "a mode difference in a real skills dir fails" 1 "$rc"; has_line "names the skills file with the mode" "DIFF mode differs: skills/a/f" "$out"
fresh; realskills r; linktree l; run
check "a real skills dir against a link to a tree compares the trees" 0 "$rc"
rm -rf "$work/l-skills"

# B7: a generated dir on one side only
fresh; rm -rf "$work/l/agents"; run
check "a generated dir missing from live fails" 1 "$rc"; has_line "says missing, not type" "DIFF missing in live: agents" "$out"
has_line "lists the render files under the missing dir" "DIFF missing in live: agents/r.md" "$out"
no_line "a missing dir is not a type difference" "DIFF type differs: agents" "$out"
fresh; rm -rf "$work/r/agents"; run
check "a generated dir only in live fails" 1 "$rc"; has_line "says only in live" "DIFF only in live: agents" "$out"
has_line "lists the live files under the extra dir" "DIFF only in live: agents/r.md" "$out"

# B2: trailing slashes
fresh; runargs "$work/r/" "$work/l/"
check "a trailing slash on both arguments changes nothing" 0 "$rc"
fresh; runargs "$work/r//" "$work/l"
check "doubled trailing slashes on the render change nothing" 0 "$rc"
fresh; echo extra >"$work/l/hooks/g"; runargs "$work/r/" "$work/l/"
check "a difference is still found with trailing slashes" 1 "$rc"; has_line "names the file despite slashes" "DIFF differs: hooks/g" "$out"

# B3: argument checks
fresh; runargs "$work/nope" "$work/l"
check "a missing render dir exits 2" 2 "$rc"; has_line "says the render dir is missing" "ERROR: rendered directory not found: $work/nope" "$out"
fresh; runargs "$work/r" "$work/nope"
check "a missing live dir exits 2" 2 "$rc"; has_line "says the live dir is missing" "ERROR: live directory not found: $work/nope" "$out"
fresh; runargs "$work/r/settings.json" "$work/l"
check "a file as the render argument exits 2" 2 "$rc"; has_line "says the render is not a dir" "ERROR: rendered is not a directory: $work/r/settings.json" "$out"
fresh; runargs "$work/r"
check "a missing argument exits 2" 2 "$rc"
if [ "$(id -u)" = 0 ]; then
  echo "skip $tag unreadable-dir checks: running as root, permissions do not apply"
else
  fresh; chmod 000 "$work/l"; runargs "$work/r" "$work/l"; chmod 755 "$work/l"
  check "an unreadable live dir exits 2" 2 "$rc"; has_line "says the live dir is unreadable" "ERROR: live directory is not readable: $work/l" "$out"
  fresh; mkdir "$work/r/hooks/sub"; mkdir "$work/l/hooks/sub"; chmod 000 "$work/r/hooks/sub"; run; chmod 755 "$work/r/hooks/sub"
  check "an unreadable subdir (a failing find) fails the script" 1 "$rc"
  has_line "names the unwalkable dir" "DIFF cannot walk (loop, deeper than 64 or unreadable): hooks" "$out"
fi
rm -rf "$work/e1" "$work/e2"; mkdir "$work/e1" "$work/e2"; runargs "$work/e1" "$work/e2"
check "two empty dirs fail: nothing was compared" 1 "$rc"
has_line "says nothing was compared" "DIFF nothing was compared (is the render or the live dir empty?)" "$out"
fresh; rm -rf "$work/e2"; mkdir "$work/e2"; runargs "$work/r" "$work/e2"
check "an empty live dir fails" 1 "$rc"; has_line "names what the empty live dir lacks" "DIFF missing in live: agents" "$out"

# B8: one jq call for the classes, one for the settings; keys by name, newline-safe, absent is explicit
mkdir -p "$work/bin"
printf '#!/bin/sh\necho x >>"%s/jqcalls"\nexec "%s" "$@"\n' "$work" "$real_jq" >"$work/bin/jq"; chmod +x "$work/bin/jq"
fresh; for i in $(seq 1 60); do echo "$i" >"$work/r/agents/f$i.md"; echo "$i" >"$work/l/agents/f$i.md"; done
: >"$work/jqcalls"; PATH="$work/bin:$PATH" runargs "$work/r" "$work/l"
check "60 generated files compare equal" 0 "$rc"
calls=$(wc -l <"$work/jqcalls" | tr -d ' ')
check "jq runs a fixed number of times, not once per entry (<= 6)" 1 "$([ "$calls" -le 6 ] && echo 1 || echo "$calls")"
fresh; jq '.["a
b"]=1' "$work/r/settings.json" >"$work/t" && mv "$work/t" "$work/r/settings.json"; run
check "a declared settings key with a newline, absent in live, fails" 1 "$rc"
has_line "prints the key escaped, on one line" 'DIFF settings.json: "a\nb": absent in live' "$out"
fresh; jq '.k="__absent__"' "$work/r/settings.json" >"$work/t" && mv "$work/t" "$work/r/settings.json"; run
check "a render value equal to the old sentinel string still fails when live lacks the key" 1 "$rc"
has_line "says the sentinel-valued key is absent" "DIFF settings.json: k: absent in live" "$out"

# secrets are never read, and a settings value is never printed
fresh
if [ "$(id -u)" = 0 ]; then
  echo "skip $tag unreadable live secret: running as root, chmod 000 does not stop root from reading"
else
  chmod 000 "$work/l/.credentials.json"
  check "the live secret really is mode 000 (the test is not vacuous)" 0 "$(smode "$work/l/.credentials.json")"
  check "the live secret is unreadable by this user" 1 "$([ -r "$work/l/.credentials.json" ] && echo 0 || echo 1)"
  run
  check "an unreadable live secret is never opened" 0 "$rc"
  chmod 600 "$work/l/.credentials.json"
fi
fresh; jq '.env={"T":"TOKEN-RENDER-1"}' "$work/r/settings.json" >"$work/t" && mv "$work/t" "$work/r/settings.json"
jq '.env={"T":"TOKEN-LIVE-2"}' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a mismatched env value fails" 1 "$rc"; has_line "names the env key" "DIFF settings.json: env: differs" "$out"
if grep -qE 'TOKEN-(RENDER-1|LIVE-2)' <<<"$out"; then echo "FAIL $tag a settings value was printed: $out"; fail=1; else echo "ok   $tag a settings value is never printed"; fi

fresh; run; has_line "merged files are skipped by design and the summary says so" "merged (not compared): settings.local.json" "$out"

fresh; run; has_line "prints a summary" "compared 5 item(s), 0 problem(s)" "$out"

dups=$(sort "$work/labels" | uniq -d)
if [ -n "$dups" ]; then echo "FAIL $tag duplicate test labels: $dups"; fail=1; else echo "ok   $tag every test label is unique"; fi
}

for sh in $shells; do suite; done
exit $fail
