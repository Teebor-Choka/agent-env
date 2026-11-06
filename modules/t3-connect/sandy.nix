# modules/t3-connect/sandy.nix
# t3-sandy: the whole life of a sandy-run T3 guest, from the machine that runs the T3 app. It starts
# the job on the sandy host, finds the guest and its one-time pairing code, tunnels the guest's port,
# links it in the app, holds until the job ends or the command is signalled, then unlinks. The guest
# script (sandy/guest.sh) and the host start script (sandy/start.sh) travel with it. See
# docs/t3-connect-setup.md, "Sandy guests".
{
  pkgs,
  t3 ? pkgs.t3-server,
}:
let
  unlinkVm = import ./unlink-vm.nix { inherit pkgs t3; };
in
pkgs.writeShellApplication {
  name = "t3-sandy";
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
    sandy_files=${./sandy}
  ''
  + builtins.replaceStrings [ "CLI_VERSION_CHECK" ] [ (import ./cli-version.nix "t3-sandy") ] (
    builtins.readFile ./sandy/t3-sandy.sh
  );
}
