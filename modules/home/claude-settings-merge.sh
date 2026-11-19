#!/usr/bin/env bash
# Merge declared settings over a live Claude Code settings.json. Claude edits that file itself (/model,
# /plugin), so it stays a real writable file: declared top-level keys win, every other key survives.
#   --declared FILE  JSON object of declared top-level keys (required)
#   --hooks FILE     JSON object event -> groups, merged by event over `hooks` (optional)
# `hooks` merges per event: a declared or rendered event replaces the live one, other events survive.
# A missing file is created. A file that is not a JSON object is moved to <file>.bak-<n> (first free n)
# and replaced. A symlink (a store path) is replaced by a real file holding the merged content. The mode
# survives a rewrite and an unchanged result is not written (mtime and bytes stay). Only the target file
# is opened; a secret or state name is refused as a target, so those files are never read. Values are
# never printed, only key names. Works on bash 3.2 (macOS /bin/bash) and Linux; needs jq.
# Usage: claude-settings-merge.sh --declared FILE [--hooks FILE] <settings.json>
# Exit: 0 merged or unchanged, 2 bad arguments or input.
set -euo pipefail

usage() { echo "usage: $0 --declared FILE [--hooks FILE] <settings.json>" >&2; exit 2; }
die() { echo "settings-merge: $*" >&2; exit 2; }

declared="" hooks="" target=""
while [ $# -gt 0 ]; do
  case $1 in
    --declared) [ $# -ge 2 ] || usage; declared=$2; shift 2 ;;
    --hooks) [ $# -ge 2 ] || usage; hooks=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$target" ] || usage; target=$1; shift ;;
  esac
done
[ -n "$declared" ] && [ -n "$target" ] || usage

command -v jq >/dev/null 2>&1 || die "jq not found"
obj() { jq -e 'type == "object"' "$1" >/dev/null 2>&1; }
[ -r "$declared" ] && obj "$declared" || die "declared settings are not a readable JSON object: $declared"
if [ -n "$hooks" ]; then
  [ -r "$hooks" ] && obj "$hooks" || die "hooks are not a readable JSON object: $hooks"
fi

# Same names as claude-config-classes.json (secret) plus the other hand-edited file.
base=${target##*/}
case $base in
  .credentials.json | daemon-auth-status.json | daemon-auth-cooldown | remote-settings* | policy-limits* | session-env | settings.local.json)
    die "refusing to touch $base: a secret, state or hand-edited file" ;;
esac
dir=$(dirname -- "$target")
[ -d "$dir" ] || die "directory not found: $dir"

if stat -c %a / >/dev/null 2>&1; then statfmt=gnu; else statfmt=bsd; fi
modeof() { if [ "$statfmt" = gnu ]; then stat -L -c %a -- "$1"; else stat -L -f %Lp "$1"; fi; }

tmp=$(mktemp "$dir/.settings-merge.XXXXXX")
trap 'rm -f "$tmp"' EXIT

live='{}'
mode=""
if [ -e "$target" ]; then
  if [ -f "$target" ] && obj "$target"; then
    live=$(jq -c . "$target")
    # a link is a store path: its mode (read-only) is not ours to keep
    if [ ! -L "$target" ]; then mode=$(modeof "$target"); fi
  else
    n=1
    while [ -e "$target.bak-$n" ] || [ -L "$target.bak-$n" ]; do n=$((n + 1)); done
    mv -- "$target" "$target.bak-$n"
    echo "settings-merge: moved a corrupt $base to $base.bak-$n" >&2
  fi
fi

jq -n --argjson live "$live" --slurpfile D "$declared" --slurpfile H "${hooks:-/dev/null}" '
  $D[0] as $d
  | $live as $l
  | ($l + ($d | del(.hooks))) as $m
  | (($l.hooks // {}) + ($d.hooks // {}) + ($H[0] // {})) as $h
  | if ($d | has("hooks")) or ($H | length > 0) then $m + {hooks: $h} else $m end' >"$tmp"

# Compare against the live bytes in the same normal form: no rewrite when nothing changes.
if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$tmp" "$target"; then
  echo "settings-merge: unchanged $target"
  exit 0
fi
# mktemp makes the file 600; a new file gets the umask's mode, an existing one keeps its own.
chmod "${mode:-$(printf '%03o' $((0666 & ~$(umask))))}" "$tmp"
mv -f -- "$tmp" "$target"
keys=$(jq -r '[keys[] | select(. != "hooks")] | join(",")' "$declared")
if [ "$(jq 'has("hooks")' "$declared")" = true ] || [ -n "$hooks" ]; then keys="${keys:+$keys,}hooks"; fi
echo "settings-merge: wrote $target (declared: $keys)"
