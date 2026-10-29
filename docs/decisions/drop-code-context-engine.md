---
title: Drop code-context-engine
status: accepted
project: agent-env
updated: 2026-10-29
---

**Context.** `pkgs.agentic-tools` carried `headroom-ai[proxy]` and `code-context-engine[local]`.
The fleet replaced the code-indexing MCP server with `codebase-memory-mcp`, so nothing installs
or calls `cce` any more. Its `[local]` extra still pulled `fastembed`, `pillow`, the tree-sitter
grammars and about 17 other locked packages into every guest, and held the pillow advisories open
(see the resolved `pillow-cve-blocked-upstream.md`).

**Decision.** Remove `code-context-engine[local]` from `pyproject.toml` and regenerate `uv.lock`.
The environment keeps the name `agentic-tools` so the consuming overlay does not change; it now
holds `headroom` only.

**Consequences.** `uv.lock` goes from 118 to 101 packages and the `aarch64-linux` environment
closure from 907 MiB to 834 MiB. `pillow` and `fastembed` leave the lock, so the 13 pillow
advisories close. The remaining weight (transformers, onnxruntime, litellm, numpy) is
`headroom-ai[proxy]`'s own dependency set, not removable without dropping the proxy extra.
`single-combined-environment.md` no longer applies: there is one tool, so no split to consider.
