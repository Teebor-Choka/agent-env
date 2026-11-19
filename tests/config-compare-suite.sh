#!/usr/bin/env bash
# Tests for modules/home/claude-config-compare.sh: a rendered config dir vs a live ~/.claude.
#   config-compare-suite.sh <compare-script> <classes.json> <fixture-dir>
set -euo pipefail
cmp=$1 classes=$2 fix=$3
fail=0
check() { # label want-exit got-exit
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected exit $2, got $3"; fail=1; fi
}
contains() { # label needle output
  if grep -qF -- "$2" <<<"$3"; then echo "ok   $1"; else echo "FAIL $1: no '$2' in: $3"; fail=1; fi
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fresh() { rm -rf "$work/r" "$work/l"; cp -R "$fix/render" "$work/r"; cp -R "$fix/live" "$work/l"; chmod -R u+w "$work/r" "$work/l"; }
run() { set +e; bash "$cmp" --classes "$classes" "$work/r" "$work/l" >"$work/out" 2>&1; rc=$?; set -e; out=$(<"$work/out"); }

fresh; run; check "identical generated config, live-only state and secrets ignored" 0 "$rc"

fresh; echo extra >"$work/l/hooks/g"; run
check "a generated file that differs fails" 1 "$rc"; contains "names the file" "hooks/g" "$out"

fresh; rm "$work/l/agents/r.md"; run
check "a generated file missing from live fails" 1 "$rc"; contains "names it" "agents/r.md" "$out"

fresh; echo x >"$work/r/agents/new.md"; run
check "a rendered file missing from live fails" 1 "$rc"; contains "names it" "agents/new.md" "$out"

fresh; echo x >"$work/l/agents/stray.md"; run
check "a live-only file in a generated dir fails" 1 "$rc"; contains "names it" "agents/stray.md" "$out"

fresh; jq '.model="opus"' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a declared settings key that differs fails" 1 "$rc"; contains "names the key" "settings.json: model" "$out"

fresh; jq 'del(.theme)' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a declared settings key missing from live fails" 1 "$rc"; contains "names the key" "settings.json: theme" "$out"

fresh; jq '.extraLive=1' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a live-only settings key is merged state, not a diff" 0 "$rc"

fresh; echo s >"$work/r/.credentials.json"; run
check "a secret in the render fails" 1 "$rc"; contains "names it" ".credentials.json" "$out"

fresh; echo x >"$work/l/brand-new-thing"; run
check "an unclassified live top-level entry fails" 1 "$rc"; contains "names it" "brand-new-thing" "$out"

fresh; echo x >"$work/r/brand-new-thing"; run
check "an unclassified rendered top-level entry fails" 1 "$rc"; contains "names it" "brand-new-thing" "$out"

fresh; mkdir "$work/l/projects" && echo x >"$work/l/projects/p"; run
check "runtime state in live is ignored" 0 "$rc"

# plugin-dirs entries are symlinks to directories (store paths): compare the trees they point at.
linkdirs() { mkdir -p "$work/$1/plugin-dirs" "$work/$1-store/p"; echo "${2:-same}" >"$work/$1-store/p/f"; ln -s "$work/$1-store/p" "$work/$1/plugin-dirs/p"; }
fresh; linkdirs r; linkdirs l; run
check "equal symlinked plugin dirs compare equal" 0 "$rc"
fresh; linkdirs r; linkdirs l other; run
check "differing symlinked plugin dirs fail" 1 "$rc"; contains "names it" "plugin-dirs/p" "$out"
rm -rf "$work/r-store" "$work/l-store"

# --- review round: exit 0 although a difference exists ---
fresh; chmod +x "$work/r/hooks/g" "$work/l/hooks/g"; chmod -x "$work/l/hooks/g"; run
check "an executable bit that differs fails" 1 "$rc"; contains "says mode" "mode differs: hooks/g" "$out"

fresh; touch "$work/l/..stash"; run
check "a top-level name starting with .. is classified" 1 "$rc"; contains "names it" "unclassified top-level entry: ..stash" "$out"

fresh; mkdir -p "$work/l/$(printf 'projects\nanything')"; run
check "a newline in a name cannot borrow another name's class" 1 "$rc"

fresh; rm -rf "$work/r/agents" "$work/l/agents"; echo a >"$work/r/agents"; echo b >"$work/l/agents"; run
check "a generated dir that is a file on both sides is compared" 1 "$rc"; contains "names it" "agents" "$out"

fresh; mkdir "$work/r/agents/sub"; run
check "an empty dir only in the render fails" 1 "$rc"; contains "names it" "missing in live: agents/sub" "$out"

fresh; mkdir "$work/l/agents/sub"; run
check "an empty dir only in live fails" 1 "$rc"; contains "names it" "only in live: agents/sub" "$out"

fresh; echo '{bad' >"$work/r/settings.json"; run
check "an invalid render settings.json fails, not skipped" 1 "$rc"; contains "says why" "settings.json: render is not a JSON object" "$out"

fresh; echo '[1]' >"$work/r/settings.json"; run
check "a non-object render settings.json fails" 1 "$rc"

fresh; echo '{bad' >"$work/l/settings.json"; run
check "an invalid live settings.json exits 1 with a message" 1 "$rc"; contains "says why" "settings.json: live is not a JSON object" "$out"

fresh; ln -s /nonexistent "$work/r/.credentials.json"; run
check "a dangling secret symlink in the render fails" 1 "$rc"; contains "is a secret finding" "secret in the render: .credentials.json" "$out"

fresh; echo s >"$work/r/hooks/.credentials.json"; echo s >"$work/l/hooks/.credentials.json"; run
check "a secret name inside a generated dir fails" 1 "$rc"; contains "is a secret finding" "secret in the render: hooks/.credentials.json" "$out"

fresh; echo secret >"$work/r/.credentials.json"; run
contains "a secret in the render is reported as a secret, not as unclassified" "secret in the render: .credentials.json" "$out"

fresh; echo c >"$work/r/CLAUDE.md"; echo d >"$work/l/CLAUDE.md"; run
check "a generated file that differs fails" 1 "$rc"; contains "names it" "differs: CLAUDE.md" "$out"

fresh; ln -s /nonexistent "$work/r/CLAUDE.md"; ln -s /nonexistent "$work/l/CLAUDE.md"; run
check "a dangling generated file fails even when both sides dangle" 1 "$rc"; contains "names it" "dangling: CLAUDE.md" "$out"

# skills is a link to a tree (the neutral skills dir): compared by content
linktree() { mkdir -p "$work/$1-skills/a"; echo "${2:-same}" >"$work/$1-skills/a/f"; ln -s "$work/$1-skills" "$work/$1/skills"; }
fresh; linktree r; linktree l; run
check "equal skills trees compare equal" 0 "$rc"
fresh; linktree r; linktree l other; run
check "differing skills trees fail" 1 "$rc"; contains "names it" "differs: skills" "$out"
fresh; linktree r; run
check "a skills link missing from live fails" 1 "$rc"; contains "names it" "missing in live: skills" "$out"
rm -rf "$work/r-skills" "$work/l-skills"

# secrets are never read, and a settings value is never printed
fresh; chmod 000 "$work/l/.credentials.json"; run
check "an unreadable live secret is never opened" 0 "$rc"
chmod 600 "$work/l/.credentials.json"
fresh; jq '.env={"T":"TOKEN-RENDER-1"}' "$work/r/settings.json" >"$work/t" && mv "$work/t" "$work/r/settings.json"
jq '.env={"T":"TOKEN-LIVE-2"}' "$work/l/settings.json" >"$work/t" && mv "$work/t" "$work/l/settings.json"; run
check "a mismatched env value fails" 1 "$rc"; contains "names the key" "settings.json: env" "$out"
if grep -qE 'TOKEN-(RENDER-1|LIVE-2)' <<<"$out"; then echo "FAIL a settings value was printed: $out"; fail=1; else echo "ok   a settings value is never printed"; fi

fresh; run; contains "merged files are skipped by design and the summary says so" "merged (not compared): settings.local.json" "$out"

fresh; run; contains "prints a summary" "compared" "$out"
exit $fail
