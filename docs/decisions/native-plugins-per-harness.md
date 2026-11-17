---
title: Native plugins per harness, raw skills for the rest
status: accepted
project: agent-env
updated: 2026-11-17
---

**Context.** Skills reached every harness as flat `SKILL.md` dirs, and Claude Code also read them
as plugins, so `implement` and `swe-workflows:implement` both listed (issue #15). Four of the five
supported harnesses (Claude Code, pi, omp, Codex, OpenCode) have a plugin form that namespaces a
skill and bundles hooks. Verified against codex 0.169, omp 18.20 and pi-coding-agent 1.5 in a
throwaway `HOME`:

- Claude Code: `--plugin-dir <closure>`.
- Codex: a `.claude-plugin/marketplace.json` marketplace works (needs `.codex-plugin/plugin.json` per
  plugin); `[marketplaces.x]` and `[plugins."p@x"] enabled = true` in `config.toml` declare it, but
  the plugin is "not installed" until `codex plugin add`. Skills show as `plugin:skill`.
- omp: reads the same marketplace (needs an `owner`); install through `omp plugin install`, state in
  `~/.omp/plugins/installed_plugins.json`. No declarative enable.
- pi: a plugin closure is already a pi package (`skills/` at its root); `packages` in
  `~/.pi/agent/settings.json` lists it by path.
- OpenCode: plugins are JS hook modules; no documented way to bundle skills.

Codex, omp, pi and OpenCode all scan `~/.agents/skills` (Claude does not).

**Decision.** One closure per plugin feeds every native path. `home.agentPlugins.native` generates one
marketplace (`agent-env`) for Codex and omp, merges pi `packages` entries by jq, and moves the raw
plugin skills out of `~/.agents/skills` into `~/.config/opencode/skills`, so a native harness never
also sees a bare copy. Skills that no plugin delivers (`home.skillLink`) stay raw in
`~/.agents/skills` and reach Claude as the generated `loose` plugin. Codex's `config.toml` is
declared as `home.file` text (it merges with `home.swePlugin`'s hook); omp and pi state is CLI-owned,
so activation drives their CLIs instead of owning the files.

**Consequences.** Codex's `plugin add` installs but exits 1 (it cannot rewrite the read-only config),
so activation checks `codex plugin list`. A rebuilt store path with the same plugin version needs the
Codex cache cleared; activation removes `~/.codex/plugins/cache/agent-env` (not yet exercised live).
pi gets skills only: no hook overlay exists for it in `home.swePlugin`. Store-closure plugins are
reproducible but not live-editable; the `loose` plugin keeps live links for its sources.
