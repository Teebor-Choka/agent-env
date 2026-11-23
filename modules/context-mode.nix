# context-mode (https://github.com/mksglu/context-mode, ELv2) release bundle as a Claude Code plugin
# dir. The bundle has no npm dependencies and uses node:sqlite (Node >= 24.15), so it only needs a
# pinned node: the manifest and hook commands call a bare `node`, rewritten to the store path.
# Shared by home.contextMode and checks.<system>.context-mode.
{ pkgs }:
let
  inherit (pkgs) lib;
  nodejs = pkgs.nodejs_24;
in
assert lib.assertMsg (lib.versionAtLeast nodejs.version "24.15") "context-mode needs node >= 24.15";
pkgs.stdenvNoCC.mkDerivation rec {
  pname = "context-mode-plugin";
  version = "2.2.2";

  src = pkgs.fetchurl {
    url = "https://github.com/mksglu/context-mode/releases/download/v${version}/context-mode.tar.gz";
    hash = "sha256-QOGKoSWynk4pr07C+KezlBQFsik8q+QYkTAqGVXmBdI=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ pkgs.jq ];

  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r . "$out"
    cd "$out"
    node='${nodejs}/bin/node'
    jq --arg n "$node" '.mcpServers[].command = $n' .claude-plugin/plugin.json > plugin.tmp
    mv plugin.tmp .claude-plugin/plugin.json
    jq --arg n "$node" \
      'walk(if type == "object" and (.command? | type) == "string" then .command |= sub("^node "; $n + " ") else . end)' \
      hooks/claude-code.json > hooks.tmp
    mv hooks.tmp hooks/claude-code.json
    # Fail the build when an upstream change leaves a bare `node` command behind.
    jq -e '[.. | .command? | strings | select(startswith("node"))] | length == 0' \
      hooks/claude-code.json .claude-plugin/plugin.json > /dev/null
    runHook postInstall
  '';

  meta = {
    description = "context-mode Claude Code plugin: sandboxed ctx_* tools and output-limiting hooks";
    homepage = "https://github.com/mksglu/context-mode";
    license = lib.licenses.elastic20;
    platforms = lib.platforms.all;
  };
}
