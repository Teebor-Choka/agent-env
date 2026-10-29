---
title: Package via uv2nix, not a hand-rolled fetch derivation
status: accepted
project: agent-env
updated: 2026-10-21
---

**Context.** Both tools were originally consumed via `uvx --from <pkg> ...` at guest-boot time.
Every fresh sandbox paid a cold network fetch (package wheels, `code-context-engine`'s embedding
model), and once that was fixed with an offline `uv` cache, resolving which parts of `uv`'s own
cache (`wheels-v6`, `archive-v0`, ...) are portable across machines turned into real work: a
first attempt vendored `uv`'s internal cache directly into a fixed-output derivation, but
`archive-v0`'s directory names are generated per invocation, not content-derived, so the build was
not reproducible — two independent builds of the same inputs produced different output hashes,
which a fixed-output derivation fundamentally cannot tolerate.[^pip-fod]

**Decision.** Package both tools with uv2nix: a `pyproject.toml` + `uv.lock` pin the exact
versions, and uv2nix turns the lock's resolved wheel set into real `buildPythonPackage`
derivations via nixpkgs' own Python infrastructure. This reuses `uv`'s resolver (so no
hand-maintained manylinux platform-tag matching) while staying fully Nix-native — no runtime
`uvx`/`pip` invocation anywhere, not even an offline resolve step.

**Consequences.** Version bumps go through the normal `uv lock` + commit workflow instead of
re-running a fetch and re-pinning a hash by hand. Packaging is scoped to Linux (see
`linux-only-no-macos.md`) since that is the only platform either tool actually needs to run on.

[^pip-fod]: A second attempt used plain `pip download` into a flat directory instead of uv's
    internal cache — this WAS reproducible (PyPI wheel files are themselves content-addressed),
    and `uv --offline --find-links <dir>` could consume it. It was dropped once uv2nix proved
    comparable in effort: the pip-download approach still ran `uv`'s own resolution logic at
    every guest boot (fast, offline, but still runtime work and still carrying platform-tag
    fragility — the first live test hit a mismatch testing from the wrong host architecture)
    rather than eliminating the runtime step entirely.
