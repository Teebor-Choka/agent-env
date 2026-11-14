# cbm-heal packaged: modules/cbm-heal.sh with an absolute bash shebang and python3 pinned to the
# store, so the launchd agent needs no PATH for either (it still finds codebase-memory-mcp and pkill
# through the PATH the agent sets). Shared by the agentic module and checks.<system>.cbm-heal.
{ pkgs }:
pkgs.writeScriptBin "cbm-heal" (
  builtins.replaceStrings
    [ "#!/usr/bin/env bash" "python3 -I" ]
    [ "#!${pkgs.bash}/bin/bash" "${pkgs.python3}/bin/python3 -I" ]
    (builtins.readFile ./cbm-heal.sh)
)
