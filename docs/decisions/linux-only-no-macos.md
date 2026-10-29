---
title: Linux only, no macOS output
status: accepted
project: agent-env
updated: 2026-10-29
---

**Context.** `headroom-ai` publishes no macOS wheel at all for 0.41.0 — PyPI only lists
`manylinux_2_28_{x86_64,aarch64}` builds (the `onnxruntime` dependency matches the same
two platforms). The personal fleet this flake serves installs the tool only inside Linux dev
microVM guests: `aarch64-linux` on the Apple Silicon host's own guests (Virtualization.framework),
and `x86_64-linux` on `ws01`, a real independently-reachable NixOS workstation. Nothing on the
macOS host installs either package through this flake — it runs `headroom` via a plain `uvx`
launchd agent instead, unaffected by this packaging.[^original-scope]

**Decision.** Expose `packages.{aarch64-linux,x86_64-linux}`, built via a small system-matrix
helper (`forEachSystem`/`mkAgenticTools` in `flake.nix`) rather than a hardcoded single system.
No macOS entry.

**Scope.** This covers `packages` only. The modules (`nixosModules.agentic`,
`darwinModules.agentic`) evaluate on both platforms; the darwin one runs headroom through `uvx`.
See [environment-modules](environment-modules.md).

**Consequences.** `nix build`/`nix flake check` need an explicit `.#packages.<system>.default`
or a Linux builder for each target system; a bare `nix build` on a non-Linux machine correctly
fails rather than silently resolving nothing. CI (`ubuntu-latest`) only builds and checks
`x86_64-linux` — adding `aarch64-linux` there would need QEMU emulation, slow for a sanity check
with no functional difference from the native build the consuming flake's own aarch64-linux
builder VM already performs. If a future need arose to run `headroom` without the `[proxy]` extra
on macOS, it would need its own package entry (and a real macOS wheel chain) — not a blanket
inclusion.

[^original-scope]: The original version of this decision scoped the flake to `x86_64-linux` only,
    on the assumption that the consuming fleet's dev-VM guests ran `x86_64-linux`. That assumption
    was wrong — the guests are `aarch64-linux` (Apple Silicon virtualization) — caught when wiring
    this flake as an input into the consuming repo and evaluating a real guest config.
