# Helpers shared by tests/hooks-cases.nix and tests/harness-cases.nix: the plugins lib, the fixture
# plugins by name, and a hook constructor.
{ lib, fix }:
let
  plugins = import ../modules/home/agent-plugins-lib.nix { inherit lib; };
in
{
  inherit plugins;
  byName = builtins.listToAttrs (
    map (p: {
      name = p.name;
      value = p;
    }) (plugins.normalize { src = "${fix}/market"; })
  );
  h =
    id: event: extra:
    {
      inherit id event;
      script = "hooks/${id}.sh";
      enforce = "warn";
    }
    // extra;
}
