#!/usr/bin/env bats
# End-to-end smoke test of the plugin render (tests/e2e/render.sh): plugin roots -> a scratch Claude config.
# Self-contained: no live ~/.claude, no network, no clones. Runs in a nix sandbox (flake check e2e-render).
#   bats tests/e2e                                  fixture marketplace (tests/fixtures/e2e)
#   E2E_PLUGIN_ROOTS=/a/plugin:/b/plugin bats tests/e2e   also render real plugin roots (fixture-only tests skip)
# Env: E2E_REPO (repo root, default ../..), E2E_HOOKS_RENDERED (JSON {plugin: hooks.json}, evaluated outside the
# sandbox; without it the test runs `nix eval`), E2E_CLAUDE (claude binary; the validate test skips without one).

REPO=${E2E_REPO:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}
FIX=$REPO/tests/fixtures/e2e
render() { bash "$REPO/tests/e2e/render.sh" "$@"; }  # via bash: a sandbox has no /usr/bin/env for the shebang
COMPARE=$REPO/modules/home/claude-config-compare.sh

fixture_roots() { printf '%s\n' "$FIX/plugins/hooky" "$FIX/plugins/styled" "$FIX/plugins/skillsonly"; }

roots() { # the plugin roots under test, one per line
  if [ -n "${E2E_PLUGIN_ROOTS:-}" ]; then tr ':' '\n' <<<"$E2E_PLUGIN_ROOTS"; else fixture_roots; fi
}

render_roots() { # out
  local out=$1 r
  local -a args=()
  while IFS= read -r r; do args+=("$r"); done < <(roots)
  render "$out" "${args[@]}"
}

fixture_only() { [ -z "${E2E_PLUGIN_ROOTS:-}" ] || skip "fixture-only test (E2E_PLUGIN_ROOTS is set)"; }

rendered_hooks() { # JSON {plugin: hooks.json} for the roots under test
  if [ -n "${E2E_HOOKS_RENDERED:-}" ] && [ -z "${E2E_PLUGIN_ROOTS:-}" ]; then cat "$E2E_HOOKS_RENDERED"; return; fi
  local expr=$BATS_TEST_TMPDIR/hooks.nix r
  {
    echo "let lib = import <nixpkgs/lib>; l = import $REPO/modules/home/agent-plugins-lib.nix { inherit lib; };"
    echo "in builtins.mapAttrs (n: p: l.renderClaudeHooks (builtins.fromJSON (builtins.readFile p))) {"
    while IFS= read -r r; do
      [ -f "$r/hooks/manifest.json" ] && echo "  \"$(basename "$r")\" = $r/hooks/manifest.json;"
    done < <(roots)
    echo "}"
  } > "$expr"
  nix eval --impure --json --file "$expr"
}

@test "render succeeds and writes plugin-dirs, agents, commands, output-styles and settings.json" {
  run render_roots "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  for d in plugin-dirs agents commands output-styles; do [ -d "$BATS_TEST_TMPDIR/out/$d" ]; done
  jq -e 'keys == ["hooks"]' "$BATS_TEST_TMPDIR/out/settings.json" >/dev/null
  while IFS= read -r r; do [ -d "$BATS_TEST_TMPDIR/out/plugin-dirs/$(basename "$r")" ]; done < <(roots)
}

@test "each plugin's hooks.json equals the render of its manifest (renderClaudeHooks, jq -S)" {
  rendered_hooks > "$BATS_TEST_TMPDIR/want.json"
  n=0
  while IFS= read -r r; do
    [ -f "$r/hooks/manifest.json" ] || continue
    p=$(basename "$r")
    [ -f "$r/hooks/hooks.json" ] || { echo "$p: manifest without hooks.json"; return 1; }
    diff <(jq -S . "$r/hooks/hooks.json") <(jq -S --arg p "$p" '.[$p]' "$BATS_TEST_TMPDIR/want.json") || { echo "$p differs"; return 1; }
    n=$((n + 1))
  done < <(roots)
  [ "$n" -gt 0 ]
}

@test "the union keeps the event keys and the group order of the plugins' hooks.json" {
  render_roots "$BATS_TEST_TMPDIR/out"
  want=$(while IFS= read -r r; do [ -f "$r/hooks/hooks.json" ] && jq -c '.hooks' "$r/hooks/hooks.json"; done < <(roots) \
    | jq -cs 'reduce .[] as $h ({}; reduce ($h | to_entries[]) as $e (.; .[$e.key] += $e.value)) | {hooks: .}')
  got=$(jq -c . "$BATS_TEST_TMPDIR/out/settings.json")
  [ "$want" = "$got" ]
  # first-seen event order is kept too
  [ "$(jq -c '.hooks | keys_unsorted' <<<"$want")" = "$(jq -c '.hooks | keys_unsorted' "$BATS_TEST_TMPDIR/out/settings.json")" ]
}

@test "fixture: the union orders groups hooky then styled and keeps both Bash groups" {
  fixture_only
  render_roots "$BATS_TEST_TMPDIR/out"
  [ "$(jq -c '[.hooks.PreToolUse[] | [.matcher, (.hooks | length)]]' "$BATS_TEST_TMPDIR/out/settings.json")" = '[["Bash",1],["Edit|Write|MultiEdit",1],["Bash",1]]' ]
  [ "$(jq -c '.hooks | keys_unsorted' "$BATS_TEST_TMPDIR/out/settings.json")" = '["PreToolUse","SessionStart"]' ]
  jq -e '.hooks.PreToolUse[2].hooks[0].command | endswith("hooks/lint.sh\"")' "$BATS_TEST_TMPDIR/out/settings.json" >/dev/null
}

@test "fixture: a plugin set without hooks renders an empty hooks map" {
  fixture_only
  render "$BATS_TEST_TMPDIR/out" "$FIX/plugins/skillsonly"
  [ "$(jq -c . "$BATS_TEST_TMPDIR/out/settings.json")" = '{"hooks":{}}' ]
}

@test "fixture: a name collision exits non-zero and names both plugins" {
  fixture_only
  run render "$BATS_TEST_TMPDIR/out" "$FIX/plugins/hooky" "$FIX/plugins/styled" "$FIX/plugins/clash"
  [ "$status" -ne 0 ]
  [[ "$output" == *styled* ]]
  [[ "$output" == *clash* ]]
  [[ "$output" == *helper.md* ]]
}

@test "fixture: two roots with one plugin name exit non-zero" {
  fixture_only
  mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  cp -R "$FIX/plugins/skillsonly" "$BATS_TEST_TMPDIR/a/same"
  cp -R "$FIX/plugins/skillsonly" "$BATS_TEST_TMPDIR/b/same"
  chmod -R u+w "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  run render "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/a/same" "$BATS_TEST_TMPDIR/b/same"
  [ "$status" -ne 0 ]
  [[ "$output" == *same* ]]
}

@test "a missing plugin root exits non-zero" {
  run render "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/no-such-plugin"
  [ "$status" -ne 0 ]
}

@test "no secret-class file in the output (classes from modules/home/claude-config-classes.json)" {
  render_roots "$BATS_TEST_TMPDIR/out"
  while IFS= read -r name; do
    found=$(find "$BATS_TEST_TMPDIR/out" -name "$name" -print)
    [ -z "$found" ] || { echo "secret-class name in the render: $found"; return 1; }
  done < <(jq -r '.secret[]' "$REPO/modules/home/claude-config-classes.json")
}

@test "the output holds copies: no symlink, and a link inside a plugin is copied as content" {
  render_roots "$BATS_TEST_TMPDIR/out"
  [ -z "$(find "$BATS_TEST_TMPDIR/out" -type l -print)" ]
  # a plugin whose skill file is a link to a file elsewhere
  mkdir -p "$BATS_TEST_TMPDIR/src/linky/.claude-plugin" "$BATS_TEST_TMPDIR/target"
  echo '{"name":"linky","version":"0.1.0","description":"d"}' > "$BATS_TEST_TMPDIR/src/linky/.claude-plugin/plugin.json"
  echo "real" > "$BATS_TEST_TMPDIR/target/data.txt"
  ln -s "$BATS_TEST_TMPDIR/target/data.txt" "$BATS_TEST_TMPDIR/src/linky/data.txt"
  render "$BATS_TEST_TMPDIR/out2" "$BATS_TEST_TMPDIR/src/linky"
  [ ! -L "$BATS_TEST_TMPDIR/out2/plugin-dirs/linky/data.txt" ]
  [ "$(cat "$BATS_TEST_TMPDIR/out2/plugin-dirs/linky/data.txt")" = real ]
  [ -z "$(find "$BATS_TEST_TMPDIR/out2" -type l -print)" ]
}

@test "the output is writable and keeps executable bits (a store source is read-only)" {
  render_roots "$BATS_TEST_TMPDIR/out"
  while IFS= read -r f; do
    [ -w "$f" ] || { echo "not writable: $f"; return 1; }
  done < <(find "$BATS_TEST_TMPDIR/out" -type f)
  while IFS= read -r r; do
    while IFS= read -r f; do
      rel=${f#"$r"/}
      if [ -x "$f" ]; then [ -x "$BATS_TEST_TMPDIR/out/plugin-dirs/$(basename "$r")/$rel" ] || { echo "lost +x: $rel"; return 1; }; fi
    done < <(find "$r" -type f)
  done < <(roots)
}

@test "claude plugin validate exits 0 for each plugin root" {
  c=${E2E_CLAUDE:-$(command -v claude || true)}
  [ -n "$c" ] || skip "claude is not on PATH (set E2E_CLAUDE)"
  while IFS= read -r r; do
    HOME=$BATS_TEST_TMPDIR "$c" plugin validate "$r" </dev/null >"$BATS_TEST_TMPDIR/v.out" 2>&1 || { cat "$BATS_TEST_TMPDIR/v.out"; return 1; }
  done < <(roots)
}

@test "fixture: the output equals the expected tree under claude-config-compare.sh, and a mutation fails it" {
  fixture_only
  render_roots "$BATS_TEST_TMPDIR/out"
  run bash "$COMPARE" --classes "$FIX/classes.json" "$BATS_TEST_TMPDIR/out" "$FIX/expected"
  [ "$status" -eq 0 ]
  # exec bit flipped
  chmod -x "$BATS_TEST_TMPDIR/out/plugin-dirs/hooky/hooks/guard.sh"
  run bash "$COMPARE" --classes "$FIX/classes.json" "$BATS_TEST_TMPDIR/out" "$FIX/expected"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode differs: plugin-dirs/hooky/hooks/guard.sh"* ]]
  chmod +x "$BATS_TEST_TMPDIR/out/plugin-dirs/hooky/hooks/guard.sh"
  # a file removed
  rm "$BATS_TEST_TMPDIR/out/commands/go.md"
  run bash "$COMPARE" --classes "$FIX/classes.json" "$BATS_TEST_TMPDIR/out" "$FIX/expected"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commands/go.md"* ]]
}
