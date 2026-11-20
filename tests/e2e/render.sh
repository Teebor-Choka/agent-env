#!/usr/bin/env bash
# Build a scratch Claude Code config dir from plugin roots.
#   render.sh <out> <plugin-root>...
# <out>/plugin-dirs/<name>   a copy of each plugin root (name = the root's directory name; no links)
# <out>/{agents,commands,output-styles}   the union of the plugins' dirs of those names
# <out>/settings.json        {"hooks": <union of every plugin's hooks/hooks.json "hooks", per event, in order>}
# A file name that two plugins both ship, or a plugin name given twice, exits 1 naming both. Nothing is read
# from ~/.claude; the sources are never written.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <out> <plugin-root>..." >&2; exit 2; }
out=$1; shift

owner=$(mktemp -d "${TMPDIR:-/tmp}/render-owner.XXXXXX")  # <kind>/<file> holds the plugin that supplied it
trap 'rm -rf "$owner"' EXIT

rm -rf "$out"
mkdir -p "$out/plugin-dirs" "$out/agents" "$out/commands" "$out/output-styles" "$owner/plugin"
hookfiles=()
for root in "$@"; do
  [ -d "$root" ] || { echo "render: no such plugin root: $root" >&2; exit 1; }
  name=$(basename "$(cd "$root" && pwd)")
  if [ -e "$owner/plugin/$name" ]; then
    echo "render: plugin name $name given twice ($(cat "$owner/plugin/$name") and $root)" >&2
    exit 1
  fi
  echo "$root" > "$owner/plugin/$name"
  cp -RL "$root" "$out/plugin-dirs/$name"
  chmod -R u+w "$out/plugin-dirs/$name"
  for kind in agents commands output-styles; do
    [ -d "$root/$kind" ] || continue
    mkdir -p "$owner/$kind"
    for f in "$root/$kind"/*; do
      [ -f "$f" ] || continue
      file=$(basename "$f")
      if [ -e "$owner/$kind/$file" ]; then
        echo "render: $kind/$file is shipped by both $(cat "$owner/$kind/$file") and $name" >&2
        exit 1
      fi
      echo "$name" > "$owner/$kind/$file"
      cp -L "$f" "$out/$kind/$file"
      chmod u+w "$out/$kind/$file"
    done
  done
  if [ -f "$root/hooks/hooks.json" ]; then hookfiles+=("$root/hooks/hooks.json"); fi
done

if [ ${#hookfiles[@]} -eq 0 ]; then
  echo '{"hooks":{}}' | jq . > "$out/settings.json"
else
  jq -n 'reduce (inputs | .hooks | to_entries[]) as $e ({}; .[$e.key] += $e.value) | {hooks: .}' "${hookfiles[@]}" > "$out/settings.json"
fi
