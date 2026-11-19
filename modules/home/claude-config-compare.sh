#!/usr/bin/env bash
# Compare a rendered Claude Code config dir with the live one (~/.claude), by class
# (claude-config-classes.json). Exit 1 and name each problem; exit 0 only when they agree; exit 2 on
# bad arguments (a missing, unreadable or non-directory argument; a trailing slash is fine).
#   generated dirs/files/links  content, file mode (executable bits, from stat) and existence must match;
#                               a link to a tree (plugin-dirs/*, skills) is walked like a dir (same file
#                               set, bytes, modes); a link name that is a real dir on both sides is walked
#                               as a dir; a dir on one side only is reported with the files under it
#   settings.json               only the keys the render declares are compared, by name (a value is never
#                               printed); live-only keys are merged state
#   merged files                listed in the summary, never compared (Claude and the user write them)
#   secret                      must not appear in the render: at the top level, inside a generated dir or
#                               inside a linked tree; never opened in the live dir (only stat'ed)
#   state                       ignored
#   anything else               fails: a new top-level entry must be classified first
# Works on bash 3.2 (macOS /bin/bash): no associative arrays, names are NUL-delimited. A name holding a
# tab, newline, CR or backslash has no class (the class file never lists one).
# Usage: claude-config-compare.sh [--classes FILE] <rendered-dir> <live-dir>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
classes="$here/claude-config-classes.json"
if [ "${1:-}" = --classes ]; then
  [ $# -ge 2 ] || { echo "usage: $0 [--classes FILE] <rendered-dir> <live-dir>" >&2; exit 2; }
  classes=$2
  shift 2
fi
[ $# -eq 2 ] || { echo "usage: $0 [--classes FILE] <rendered-dir> <live-dir>" >&2; exit 2; }
[ -r "$classes" ] || { echo "ERROR: classes file not readable: $classes" >&2; exit 2; }

dir_arg() { # what path -> D (normalised, absolute)
  local p=$2
  [ -e "$p" ] || { echo "ERROR: $1 directory not found: $p" >&2; exit 2; }
  [ -d "$p" ] || { echo "ERROR: $1 is not a directory: $p" >&2; exit 2; }
  [ -r "$p" ] && [ -x "$p" ] || { echo "ERROR: $1 directory is not readable: $p" >&2; exit 2; }
  while [ "${p%/}" != "$p" ]; do p=${p%/}; done
  [ -n "$p" ] || p=/
  D=$(cd -- "$p" && pwd)
}
dir_arg rendered "$1"; r=$D
dir_arg live "$2"; l=$D

problems=0
compared=0
maxdepth=64
tab=$'\t' nl=$'\n'
tdir=$(mktemp -d)
trap 'rm -rf "$tdir"' EXIT
bad() { echo "DIFF $*"; problems=$((problems + 1)); }

# Class membership is a lookup in one string loaded by a single jq call: "\nclass<TAB>name\n...".
# Exact match, and no fork per entry.
C=$nl$(jq -r 'to_entries[] | select(.value | type == "array") | .key as $k | .value[] | [$k, .] | @tsv' "$classes")$nl
s=$(jq -r .settings.file "$classes")
has() { # class name
  case $2 in *"$tab"* | *"$nl"* | *$'\r'* | *\\*) return 1 ;; esac
  [[ $C == *"$nl$1$tab$2$nl"* ]]
}
gen=()
while IFS=$'\t' read -r cls nm; do
  case $cls in generated_dirs | generated_files | generated_links) gen+=("$nm") ;; esac
done <<<"$C"
merged=$(
  while IFS=$'\t' read -r cls nm; do
    if [ "$cls" = merged_files ]; then echo "$nm"; fi
  done <<<"$C" | paste -sd, - | sed 's/,/, /g'
)

present() { [ -e "$1" ] || [ -L "$1" ]; }
# Mode bits from stat, detected once (GNU stat -c, else BSD stat -f). `[ -x ]` would depend on who runs.
if stat -c %a / >/dev/null 2>&1; then statfmt=gnu; else statfmt=bsd; fi
modeof() { if [ "$statfmt" = gnu ]; then stat -L -c %a -- "$1"; else stat -L -f %Lp "$1"; fi; }
xbits() { local m; m=$(modeof "$1"); echo $(((8#$m & 73) != 0)); } # any of u/g/o x

# find into a fresh NUL-list file: WALK. A failing find (loop, unreadable, over the depth cap) is a problem.
seq=0
walk() { # label follow(0|1) root [depth]
  seq=$((seq + 1))
  WALK="$tdir/w$seq"
  local fl=() ok=1 f par tgt
  if [ "$2" = 1 ]; then fl=(-L); fi
  find ${fl[@]+"${fl[@]}"} "$3" -mindepth 1 -maxdepth "${4:-$maxdepth}" -print0 >"$WALK" 2>/dev/null || ok=0
  # Not every find reports a link loop as an error (BSD find does not): a link to one of its own
  # ancestors is a loop whichever find runs.
  if [ "$ok" = 1 ] && [ "$2" = 1 ]; then
    while IFS= read -r -d '' f; do
      if [ -L "$f" ] && [ -d "$f" ]; then
        tgt=$(cd -- "$f" && pwd -P)
        par=$(cd -- "${f%/*}" && pwd -P)
        case "$par/" in "$tgt/"*) ok=0; break ;; esac
      fi
    done <"$WALK"
  fi
  if [ "$ok" = 0 ]; then bad "cannot walk (loop, deeper than $maxdepth or unreadable): $1"; fi
}

# Everything under a one-sided dir (or link to a tree), one line per entry.
below() { # side rel message
  local base=$1/$2 f follow=0
  [ -d "$base" ] || return 0
  if [ -L "$base" ]; then follow=1; fi
  walk "$2" "$follow" "$base"
  local t=$WALK
  while IFS= read -r -d '' f; do
    compared=$((compared + 1))
    bad "$3: $2/${f#"$base"/}"
  done <"$t"
}

# One path, relative to both roots. top=1: a one-sided dir also lists what is under it.
# inlink=1: found by a -L walk, so a dir needs no further walk.
compare_path() { # rel [top] [inlink]
  local rel=$1 top=${2:-0} inlink=${3:-0} a="$r/$1" b="$l/$1"
  compared=$((compared + 1))
  if ! present "$b"; then
    bad "missing in live: $rel"
    if [ "$top" = 1 ]; then below "$r" "$rel" "missing in live"; fi
    return 0
  fi
  if ! present "$a"; then
    bad "only in live: $rel"
    if [ "$top" = 1 ]; then below "$l" "$rel" "only in live"; fi
    return 0
  fi
  if { [ -L "$a" ] && [ ! -e "$a" ]; } || { [ -L "$b" ] && [ ! -e "$b" ]; }; then bad "dangling: $rel"; return 0; fi
  if [ -d "$a" ] || [ -d "$b" ]; then
    if [ -d "$a" ] && [ -d "$b" ]; then
      # a link to a tree is walked (-L) for set, bytes and modes; a real dir pair is walked by the caller
      if [ "$inlink" = 0 ] && { [ -L "$a" ] || [ -L "$b" ]; }; then compare_linked "$rel"; fi
    else
      bad "type differs: $rel"
    fi
    return 0
  fi
  cmp -s "$a" "$b" || { bad "differs: $rel"; return 0; }
  [ "$(xbits "$a")" = "$(xbits "$b")" ] || bad "mode differs: $rel"
}

# Both sides' entries under a path that is a link (to a tree) on at least one side.
compare_linked() { # rel
  local rel=$1 side f t
  for side in "$r" "$l"; do
    walk "$rel" 1 "$side/$rel"
    local list=$WALK
    while IFS= read -r -d '' f; do
      t=${f#"$side/$rel"/}
      if [ "$side" = "$l" ] && present "$r/$rel/$t"; then continue; fi
      compare_path "$rel/$t" 0 1
    done <"$list"
  done
}

# Both sides are real dirs: entry by entry, render side first, then live-only entries.
compare_dir() { # rel
  local rel=$1 side f t
  for side in "$r" "$l"; do
    walk "$rel" 0 "$side/$rel"
    local list=$WALK
    while IFS= read -r -d '' f; do
      t=${f#"$side/$rel"/}
      if [ "$side" = "$l" ] && present "$r/$rel/$t"; then continue; fi
      compare_path "$rel/$t"
    done <"$list"
  done
}

# -- top level: every entry on either side has a class --
check_top() {
  local n=$1
  if has secret "$n"; then
    if present "$r/$n"; then bad "secret in the render: $n"; fi
  elif has state "$n" || has generated_dirs "$n" || has generated_files "$n" \
    || has generated_links "$n" || has merged_files "$n" || [ "$n" = "$s" ]; then
    :
  else
    bad "unclassified top-level entry: $n"
  fi
}
for d in "$r" "$l"; do
  walk "$d" 0 "$d" 1
  top=$WALK
  while IFS= read -r -d '' p; do
    n=${p#"$d"/}
    if [ "$d" = "$l" ] && present "$r/$n"; then continue; fi
    check_top "$n"
  done <"$top"
done

# -- generated names: dirs, files and links share one path --
for n in ${gen[@]+"${gen[@]}"}; do
  if ! present "$r/$n" && ! present "$l/$n"; then continue; fi
  if [ -d "$r/$n" ] && [ -d "$l/$n" ] && [ ! -L "$r/$n" ] && [ ! -L "$l/$n" ]; then
    compare_dir "$n"
  else
    compare_path "$n" 1
  fi
  # a secret name anywhere in the render's tree, through links too
  if [ -d "$r/$n" ]; then
    walk "$n" 1 "$r/$n"
    list=$WALK
    while IFS= read -r -d '' f; do
      t=${f#"$r/$n"/}
      if has secret "${t##*/}"; then bad "secret in the render: $n/$t"; fi
    done <"$list"
  fi
done

# -- settings.json: declared keys only, by name, one jq pass; a value is never printed --
if present "$r/$s"; then
  rok=0 lok=0
  jq -e 'type == "object"' "$r/$s" >/dev/null 2>&1 && rok=1 || bad "$s: render is not a JSON object"
  if [ ! -f "$l/$s" ]; then bad "missing in live: $s"
  else
    jq -e 'type == "object"' "$l/$s" >/dev/null 2>&1 && lok=1 || bad "$s: live is not a JSON object"
  fi
  if [ "$rok" = 1 ] && [ "$lok" = 1 ]; then
    res=$(jq -n -r --arg s "$s" --slurpfile R "$r/$s" --slurpfile L "$l/$s" '
      $R[0] as $R | $L[0] as $L | ($R | keys) as $ks
      | ($ks | length),
        ($ks[] | . as $k
          | (if ($L | has($k) | not) then "absent in live" elif $R[$k] != $L[$k] then "differs" else empty end) as $why
          | "\($s): \(if test("[\u0001-\u001f\u007f]") then @json else . end): \($why)")')
    first=1
    while IFS= read -r line; do
      if [ "$first" = 1 ]; then compared=$((compared + line)); first=0; else bad "$line"; fi
    done <<<"$res"
  fi
fi

[ "$compared" -gt 0 ] || bad "nothing was compared (is the render or the live dir empty?)"
echo "compared $compared item(s), $problems problem(s)"
[ -z "$merged" ] || echo "merged (not compared): $merged"
[ "$problems" -eq 0 ]
