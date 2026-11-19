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

fresh; run; contains "prints a summary" "compared" "$out"
exit $fail
