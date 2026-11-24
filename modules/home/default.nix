# modules/home/default.nix
# home-manager modules that deliver agent plugins and skills to every harness. Imported through
# `homeModules.agentic`; modules/agentic.nix also registers them as home-manager sharedModules.
{
  imports = [
    ./skill-link.nix # opt-in: home.skillLink: flatten SKILL.md dirs into ~/.claude/skills
    ./swe-plugin.nix # opt-in: home.swePlugin: wire the swe-workflows policy-gate plugin per harness
    ./context-mode.nix # opt-in: home.contextMode: deliver the context-mode plugin to Claude Code
    ./agent-plugins.nix # opt-in: home.agentPlugins: deliver marketplace plugins to every harness
    ./claude-settings.nix # opt-in: home.claudeSettings: merge declared keys into ~/.claude/settings.json
    ./claude-statusline.nix # opt-in: home.claudeStatusline: declare the Claude Code statusLine
  ];
}
