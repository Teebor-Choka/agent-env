# modules/t3-connect/sandbox.nix
# nixosModules.t3-sandbox: the whole t3 guest in one import. It is `nixosModules.sandbox` (the
# `user@sandbox` account and the harnesses) plus `nixosModules.t3-connect` (t3 serve, mesh join, link
# support), wired so the t3 user and harnesses follow the sandbox's. Needs one setting,
# `t3Connect.mesh.loginServer`; everything else has a default.
#
# Import this module instead of the two it combines. Importing `sandbox` or `t3-connect` as well
# declares their options twice and fails evaluation. A bare builder that takes a single module name
# and passes no options cannot set the login server: set it in a wrapper module of your own.
{ self }:
{ config, lib, ... }:
{
  imports = [
    self.nixosModules.sandbox
    self.nixosModules.t3-connect
  ];

  # mkDefault: a consumer can still set any of these.
  config.t3Connect = {
    enable = lib.mkDefault true;
    user = lib.mkDefault config.sandbox.user;
    harnesses = lib.mkDefault config.sandbox.tools;
    mesh.enable = lib.mkDefault true;
  };
}
