#!/usr/bin/env bash
# Unit test for modules/home/agent-plugins-lib.nix: marketplace.json -> normalized plugin records.
# jq comparisons over the normalized records.
#   agent-plugins-suite.sh                  one pure `nix eval` (no VM); run anywhere
#   agent-plugins-suite.sh <json> <fixdir>  records already evaluated (the flake check, in the sandbox)
set -euo pipefail
fail=0
check() { # label want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $2, got $3"; fail=1; fi
}

if [ $# -eq 2 ]; then
  out=$(cat "$1")
  fix=$2
else
  cd "$(dirname "$0")/.."
  fix="$PWD/tests/fixtures/agent-plugins"
  out=$(nix eval --impure --json --expr "
    let l = import ./modules/home/agent-plugins-lib.nix { lib = import <nixpkgs/lib>; };
        ps = l.normalize { src = \"$fix\"; exclude = [ \"skipme\" ]; };
        names = [ \"alpha\" \"swe-workflows\" ];
    in { names = map (p: p.name) ps; byName = builtins.listToAttrs (map (p: { name = p.name; value = p; }) ps);
         manifest = l.marketplaceManifest { name = \"agent-env\"; inherit names; };
         codex = l.codexConfig { marketplace = \"agent-env\"; path = \"/store/mk\"; inherit names; }; }")
fi
get() { jq -c "$1" <<<"$out"; }

check "plugin names, exclude applied" '["solo","multi","bundle","unversioned"]' "$(get '.names')"
check "skills-mode skill names, linked by frontmatter name" '["a","b","odd-named"]' "$(get '.byName.multi.skillNames')"
check "frontmatter-named skill points at its dir" "\"$fix/multi/odd\"" "$(get '.byName.multi.skills["odd-named"]')"
check "dir-mode skill names from readDir" '["one","two"]' "$(get '.byName.bundle.skillNames')"
check "dir-mode ignores non-directories" 'false' "$(get '.byName.bundle.skillNames | index("README.md") != null')"
check "dir-mode root" "\"$fix/bundle\"" "$(get '.byName.bundle.root')"
check "skills-mode has no root" 'null' "$(get '.byName.solo.root')"
check "skill source path" "\"$fix/tools/solo\"" "$(get '.byName.solo.skills.solo')"
check "version from metadata" '"1.2.0"' "$(get '.byName.solo.version')"
check "no version when the marketplace gives none" 'null' "$(get '.byName.unversioned.version')"
check "author from marketplace owner" '{"name":"Fixture Owner"}' "$(get '.byName.solo.author')"

# --- the generated marketplace read by Codex and omp (one dir-mode entry per plugin closure) ---
check "marketplace name" '"agent-env"' "$(get '.manifest.name')"
check "marketplace has an owner (omp requires one)" '"agent-env"' "$(get '.manifest.owner.name')"
check "marketplace lists every plugin, in order" '["alpha","swe-workflows"]' "$(get '[.manifest.plugins[].name]')"
check "marketplace entries are dir-mode relative sources" '["./alpha","./swe-workflows"]' "$(get '[.manifest.plugins[].source]')"
# --- the Codex config fragment: a read-only config.toml declares the marketplace and the enables ---
codex=$(jq -r .codex <<<"$out")
check "codex: marketplace table" '1' "$(grep -c '^\[marketplaces.agent-env\]$' <<<"$codex")"
check "codex: local source path" '1' "$(grep -c '^source = "/store/mk"$' <<<"$codex")"
check "codex: one enabled table per plugin" '2' "$(grep -c '^enabled = true$' <<<"$codex")"
check "codex: plugin key is name@marketplace" '1' "$(grep -c '^\[plugins."swe-workflows@agent-env"\]$' <<<"$codex")"
exit $fail
