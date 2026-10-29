# modules/home/default.nix
# home-manager modules that deliver agent plugins and skills to every harness. Imported through
# `homeModules.agentic`; modules/agentic.nix also registers them as home-manager sharedModules.
{
  imports = [
    ./skill-link.nix # opt-in: home.skillLink: flatten SKILL.md dirs into ~/.claude/skills
    ./swe-plugin.nix # opt-in: home.swePlugin: wire the swe-process policy-gate plugin per harness
    ./agent-plugins.nix # opt-in: home.agentPlugins: deliver marketplace plugins to every harness
  ];
}
