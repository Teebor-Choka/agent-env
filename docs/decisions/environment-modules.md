---
title: The environment modules live here, not with the sandbox builder
status: accepted
project: agent-env
updated: 2026-10-29
---

**Context.** The agent setup (which harnesses run, their settings, MCP wiring, headroom routing,
plugin and skill delivery) lived in a personal config flake and in the VM library `nix-vm`.
Headroom is packaged here, so its version, its service and its routing sat in three repos.
`nix-vm` builds and starts VMs; the agent setup needs none of that.

**Decision.** This flake owns the environment as modules: `nixosModules.agentic`,
`darwinModules.agentic` (one file, platform fixed per export), `overlays.default`, and the
home-manager modules `home.agentPlugins`, `home.skillLink` and `home.swePlugin`. The module
registers its overlay and the home-manager modules itself. Anything about the sandbox is an option
the builder sets: `agentic.user`, `sessionsDir`, `extensionsDir`, `extensionsPackage`,
`ephemeralDisk`. Private content (skill repos, dotagents) never becomes an input: the consumer
passes store paths in.

**Consequences.** The module needs the home-manager NixOS or nix-darwin module. It clears
`home.gitClone` only when that option exists, so it does not depend on `nix-vm`. The
platform is a static argument per export because reading `pkgs.stdenv` or `pkgs.system` inside a
module recurses infinitely in the module system's `_module.freeformType` pass. Verified by moving
the code out of the consuming flake: the built system paths of every host and guest stayed
identical.

**Set aside.** A separate private repo for the agent setup: the generic part is public already
and the personal values stay in the consuming flake, so nothing needs scrubbing.

**Sandbox variant.** `nixosModules.sandbox` is a basic `user@sandbox`, not the dev-home module and
not a user-less image. It creates one ordinary account with a minimal home and writes each chosen
harness's config there once (systemd-tmpfiles `C`: copy if absent), as plain user-owned, writable
files, the way a person who had run each tool once would have them. That keeps Claude Code's
onboarding flag and MCP registration in `~/.claude.json`, so the user can still `claude mcp add`,
and it needs no home-manager. The proxy runs as a `DynamicUser` service. It sets no model or
provider. sandy's guest autologins root and runs the job as root, which Claude Code also refuses
for some modes, so the job is run as the user with `runuser -u user --`, which keeps the injected
environment. Everything the two modules agree on (proxy flags, the MCP wrapper) lives in
`modules/shared.nix`. Config locations and opt-outs come from the vendors' docs, checked 2026-10-29:
code.claude.com/docs (settings, env vars), learn.chatgpt.com/docs/config-file, opencode.ai/docs/config.

**Set aside.** A user-less sandbox with the config in system locations (`/etc/claude-code`,
`/etc/codex`, `$OPENCODE_CONFIG`): Claude's `managed-mcp.json` takes exclusive control of MCP servers
(no `claude mcp add`), and the user asked for a basic user with its own home, not a bare image.
