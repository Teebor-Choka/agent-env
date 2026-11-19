#!/usr/bin/env bash
# Compare a rendered Claude Code config dir with the live one (~/.claude), by class
# (claude-config-classes.json). Exit 1 and name each problem; exit 0 when they agree.
#   generated dirs/files  must match exactly (content, and no file on one side only)
#   settings.json         only the keys the render declares are compared; live-only keys are merged state
#   secret                must not appear in the render; never read in the live dir
#   state                 ignored
#   anything else         fails: a new top-level entry must be classified first
# Usage: claude-config-compare.sh [--classes FILE] <rendered-dir> <live-dir>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
classes="$here/claude-config-classes.json"
if [ "${1:-}" = --classes ]; then classes=$2; shift 2; fi
[ $# -eq 2 ] || { echo "usage: $0 [--classes FILE] <rendered-dir> <live-dir>" >&2; exit 2; }
r=$1 l=$2
problems=0
bad() { echo "DIFF $*"; problems=$((problems + 1)); }
list() { jq -r "$1[]?" "$classes"; }
has() { list "$1" | grep -qxF -- "$2"; }

# -- top level: every entry on either side has a class --
declare -A seen=()
for d in "$r" "$l"; do
  for p in "$d"/* "$d"/.[!.]* ; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    seen[$(basename "$p")]=1
  done
done
for n in "${!seen[@]}"; do
  if has .secret "$n"; then
    [ -e "$r/$n" ] && bad "secret in the render: $n"
  elif has .state "$n" || has .generated_dirs "$n" || has .generated_files "$n" \
    || has .generated_links "$n" || has .merged_files "$n" || [ "$n" = "$(jq -r .settings.file "$classes")" ]; then
    :
  else
    bad "unclassified top-level entry: $n"
  fi
done

# -- generated dirs: same file set, same bytes --
compared=0
for n in $(list .generated_dirs); do
  [ -e "$r/$n" ] || [ -e "$l/$n" ] || continue
  while IFS= read -r f; do
    compared=$((compared + 1))
    if [ ! -e "$l/$n/$f" ]; then bad "missing in live: $n/$f"
    elif [ ! -e "$r/$n/$f" ]; then bad "only in live: $n/$f"
    elif [ -d "$r/$n/$f" ] || [ -d "$l/$n/$f" ]; then
      # a symlink to a directory (plugin-dirs/*): compare the trees, following links
      diff -rq "$r/$n/$f/" "$l/$n/$f/" >/dev/null 2>&1 || bad "differs: $n/$f"
    elif ! cmp -s "$r/$n/$f" "$l/$n/$f"; then bad "differs: $n/$f"; fi
  done < <({ [ -d "$r/$n" ] && (cd "$r/$n" && find . -type f -o -type l); [ -d "$l/$n" ] && (cd "$l/$n" && find . -type f -o -type l); } | sed 's|^\./||' | sort -u)
done
for n in $(list .generated_files); do
  [ -e "$r/$n" ] || [ -e "$l/$n" ] || continue
  compared=$((compared + 1))
  if [ ! -e "$l/$n" ]; then bad "missing in live: $n"
  elif [ ! -e "$r/$n" ]; then bad "only in live: $n"
  elif ! cmp -s "$r/$n" "$l/$n"; then bad "differs: $n"; fi
done

# -- settings.json: declared keys only --
s=$(jq -r .settings.file "$classes")
if [ -f "$r/$s" ]; then
  if [ ! -f "$l/$s" ]; then bad "missing in live: $s"
  else
    while IFS= read -r k; do
      compared=$((compared + 1))
      want=$(jq -cS --arg k "$k" '.[$k]' "$r/$s")
      got=$(jq -cS --arg k "$k" 'if has($k) then .[$k] else "__absent__" end' "$l/$s")
      [ "$want" = "$got" ] || bad "$s: $k"
    done < <(jq -r 'keys[]' "$r/$s")
  fi
fi

echo "compared $compared item(s), $problems problem(s)"
[ "$problems" -eq 0 ]
