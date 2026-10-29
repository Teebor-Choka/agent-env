---
title: The environment modules live here, not with the sandbox builder
status: accepted
project: agentic-pkgs
updated: 2026-10-29
---

**Context.** The agent setup (which harnesses run, their settings, MCP wiring, headroom routing,
plugin and skill delivery) lived in a personal config flake and in the VM library `nix-modules`.
Headroom is packaged here, so its version, its service and its routing sat in three repos.
`nix-modules` builds and starts VMs; the agent setup needs none of that.

**Decision.** This flake owns the environment as modules: `nixosModules.agentic`,
`darwinModules.agentic` (one file, platform fixed per export), `overlays.default`, and the
home-manager modules `home.agentPlugins`, `home.skillLink` and `home.swePlugin`. The module
registers its overlay and the home-manager modules itself. Anything about the sandbox is an option
the builder sets: `agentic.user`, `sessionsDir`, `extensionsDir`, `extensionsPackage`,
`ephemeralDisk`. Private content (skill repos, dotagents) never becomes an input: the consumer
passes store paths in.

**Consequences.** The module needs the home-manager NixOS or nix-darwin module. It clears
`home.gitClone` only when that option exists, so it does not depend on `nix-modules`. The
platform is a static argument per export because reading `pkgs.stdenv` or `pkgs.system` inside a
module recurses infinitely in the module system's `_module.freeformType` pass. Verified by moving
the code out of the consuming flake: the built system paths of every host and guest stayed
identical.

**Set aside.** A separate private repo for the agent setup: the generic part is public already
and the personal values stay in the consuming flake, so nothing needs scrubbing.
