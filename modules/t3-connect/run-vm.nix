# modules/t3-connect/run-vm.nix
# t3-run-vm: the whole life of a T3 guest that has no mesh and no sshd, from the machine that runs the T3 app.
# It starts the guest's unit on its host, finds the guest and its one-time pairing code, tunnels the guest's
# port, links it in the app, holds until the unit stops or the command is signalled, then unlinks. The
# host-side start script is not part of it: --start-script names it. See docs/t3-connect-setup.md, "VMs without
# a mesh".
{
  pkgs,
  t3 ? pkgs.t3-server,
}:
let
  unlinkVm = import ./unlink-vm.nix { inherit pkgs t3; };
in
pkgs.writeShellApplication {
  name = "t3-run-vm";
  # ssh is the system's: it has the user's config, keys and agent.
  runtimeInputs = [
    unlinkVm
    pkgs.jq
    pkgs.gnused
    pkgs.coreutils
    pkgs.curl
  ];
  text = ''
    t3_default=${t3}/bin/t3
  ''
  + builtins.replaceStrings [ "CLI_VERSION_CHECK" ] [ (import ./cli-version.nix "t3-run-vm") ] (
    builtins.readFile ./run-vm/run-vm.sh
  );
}
