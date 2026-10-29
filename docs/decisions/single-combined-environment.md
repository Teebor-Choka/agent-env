---
title: One combined environment, not a package per tool
status: superseded by drop-code-context-engine.md
project: agent-env
updated: 2026-10-21
---

**Context.** `headroom-ai` and `code-context-engine` are always installed together on every guest
that wants either one — the consuming flake's `agentic.nix` module installs both whenever the
agentic tooling is enabled, never one without the other. uv2nix builds the whole workspace's
resolved dependency set as a single Python package set regardless; splitting the two tools into
genuinely separate installable packages would mean restructuring this repo as a multi-member uv
workspace (one `pyproject.toml` per tool under a `packages/` directory) purely to get two narrower
`mkVirtualEnv` closures.[^split]

**Decision.** Expose one environment, `agentic-tools`, built with `mkVirtualEnv` over
`workspace.deps.default` — both `headroom` and `cce` land on the same `PATH`.

**Consequences.** The consuming flake installs one package to get both CLIs; there is no scenario
today where only one is wanted. If that changes, reconsider the multi-workspace split from
`[^split]` rather than keeping the combined environment just for inertia.

[^split]: A multi-member uv workspace was considered and dropped as unneeded complexity for a
    two-package flake with no independent-installation requirement — the two tools do not conflict
    on `PATH`, and a combined closure is simpler to build, lock, and reason about than two.
