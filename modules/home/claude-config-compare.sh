#!/usr/bin/env bash
# Compare a rendered Claude Code config dir with the live one (~/.claude), by class
# (claude-config-classes.json). Exit 1 and name each problem; exit 0 only when they agree.
#   generated dirs/files/links  content, file mode (executable bit) and existence must match; a link to a
#                               tree (plugin-dirs/*, skills) is compared by tree; empty dirs count
#   settings.json               only the keys the render declares are compared, by name (a value is never
#                               printed); live-only keys are merged state
#   merged files                listed in the summary, never compared (Claude and the user write them)
#   secret                      must not appear in the render, at the top level or inside a generated dir;
#                               never opened in the live dir (only stat'ed)
#   state                       ignored
#   anything else               fails: a new top-level entry must be classified first
# Works on bash 3.2 (macOS /bin/bash): no associative arrays, names are NUL-delimited.
# Usage: claude-config-compare.sh [--classes FILE] <rendered-dir> <live-dir>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
classes="$here/claude-config-classes.json"
if [ "${1:-}" = --classes ]; then classes=$2; shift 2; fi
[ $# -eq 2 ] || { echo "usage: $0 [--classes FILE] <rendered-dir> <live-dir>" >&2; exit 2; }
r=$1 l=$2
problems=0
compared=0
bad() { echo "DIFF $*"; problems=$((problems + 1)); }
list() { jq -r ".$1[]?" "$classes"; }
# exact membership (a name with a newline cannot borrow another name's class)
has() { jq -e --arg n "$2" "(.$1 // []) | index(\$n) != null" "$classes" >/dev/null; }
present() { [ -e "$1" ] || [ -L "$1" ]; }
exe() { if [ -x "$1" ]; then echo 1; else echo 0; fi; }

# One generated path (a file, a link, or a link to a tree), relative to both roots.
compare_path() {
  local rel=$1 a="$r/$1" b="$l/$1"
  compared=$((compared + 1))
  if ! present "$b"; then bad "missing in live: $rel"; return; fi
  if ! present "$a"; then bad "only in live: $rel"; return; fi
  if { [ -L "$a" ] && [ ! -e "$a" ]; } || { [ -L "$b" ] && [ ! -e "$b" ]; }; then bad "dangling: $rel"; return; fi
  if [ -d "$a" ] || [ -d "$b" ]; then
    if [ -d "$a" ] && [ -d "$b" ]; then
      # a link to a tree: compare what it points at; a real dir is walked entry by entry by the caller
      if [ -L "$a" ] || [ -L "$b" ]; then diff -rq "$a/" "$b/" >/dev/null 2>&1 || bad "differs: $rel"; fi
    else
      bad "type differs: $rel"
    fi
    return
  fi
  cmp -s "$a" "$b" || { bad "differs: $rel"; return; }
  [ "$(exe "$a")" = "$(exe "$b")" ] || bad "mode differs: $rel"
}

# -- top level: every entry on either side has a class --
check_top() {
  local n=$1
  if has secret "$n"; then
    if present "$r/$n"; then bad "secret in the render: $n"; fi
  elif has state "$n" || has generated_dirs "$n" || has generated_files "$n" \
    || has generated_links "$n" || has merged_files "$n" || [ "$n" = "$(jq -r .settings.file "$classes")" ]; then
    :
  else
    bad "unclassified top-level entry: $n"
  fi
}
for d in "$r" "$l"; do
  while IFS= read -r -d '' p; do
    n=${p#"$d"/}
    if [ "$d" = "$l" ] && present "$r/$n"; then continue; fi
    check_top "$n"
  done < <(find "$d" -mindepth 1 -maxdepth 1 -print0)
done

# -- generated dirs: same entries, same bytes, same mode (render side first, then live-only entries) --
for n in $(list generated_dirs); do
  if ! present "$r/$n" && ! present "$l/$n"; then continue; fi
  if [ -d "$r/$n" ] && [ -d "$l/$n" ]; then
    for side in "$r" "$l"; do
      while IFS= read -r -d '' f; do
        rel=${f#"$side/$n"/}
        if [ "$side" = "$l" ] && present "$r/$n/$rel"; then continue; fi
        if [ "$side" = "$r" ] && has secret "$(basename "$rel")"; then
          bad "secret in the render: $n/$rel"
          continue
        fi
        compare_path "$n/$rel"
      done < <(find "$side/$n" -mindepth 1 \( -type f -o -type l -o -type d \) -print0)
    done
  elif [ -d "$r/$n" ] || [ -d "$l/$n" ]; then
    bad "type differs: $n"
  else
    compare_path "$n"
  fi
done
for n in $(list generated_files) $(list generated_links); do
  if present "$r/$n" || present "$l/$n"; then compare_path "$n"; fi
done

# -- settings.json: declared keys only, by name --
s=$(jq -r .settings.file "$classes")
if present "$r/$s"; then
  rok=0 lok=0
  jq -e 'type == "object"' "$r/$s" >/dev/null 2>&1 && rok=1 || bad "$s: render is not a JSON object"
  if [ ! -f "$l/$s" ]; then bad "missing in live: $s"
  else
    jq -e 'type == "object"' "$l/$s" >/dev/null 2>&1 && lok=1 || bad "$s: live is not a JSON object"
  fi
  if [ "$rok" = 1 ] && [ "$lok" = 1 ]; then
    while IFS= read -r k; do
      compared=$((compared + 1))
      want=$(jq -cS --arg k "$k" '.[$k]' "$r/$s")
      got=$(jq -cS --arg k "$k" 'if has($k) then .[$k] else "__absent__" end' "$l/$s")
      [ "$want" = "$got" ] || bad "$s: $k"
    done < <(jq -r 'keys[]' "$r/$s")
  fi
fi

merged=$(list merged_files | paste -sd, - | sed 's/,/, /g')
echo "compared $compared item(s), $problems problem(s)"
[ -z "$merged" ] || echo "merged (not compared): $merged"
[ "$problems" -eq 0 ]
