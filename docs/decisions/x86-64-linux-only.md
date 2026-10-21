---
title: x86_64-linux only, no macOS or aarch64 output
status: accepted
project: agentic-pkgs
updated: 2026-10-21
---

**Context.** `headroom-ai` publishes no macOS wheel at all for 0.41.0 — PyPI only lists a
`manylinux_2_28_x86_64` build. Both tools are consumed exclusively by `x86_64-linux` dev microVM
guests in the personal fleet this flake serves; nothing on the macOS host or any aarch64 target
installs either package through this flake (the host runs `headroom` via a plain `uvx` launchd
agent, unaffected by this packaging).

**Decision.** Expose `packages.x86_64-linux` only, not a `forAllSystems` matrix. The flake
hardcodes `system = "x86_64-linux"` rather than genericizing over `lib.systems.flakeExposed`.

**Consequences.** `nix build`/`nix flake check` need an explicit `.#packages.x86_64-linux.default`
or a Linux builder (this repo always builds on a remote x86_64-linux builder from a macOS host
already, so this adds no new friction); a bare `nix build` on a non-Linux machine correctly fails
rather than silently resolving nothing. If a future need arose to run `headroom` without the
`[proxy]` extra on macOS, it would need its own package entry (and its own system attrset) in this
flake — not a blanket multi-system matrix, since `code-context-engine` has no established macOS
need here either.
