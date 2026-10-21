---
title: agentic-pkgs
kind: overview
project: agentic-pkgs
updated: 2026-10-21
---

## Purpose

Nix packaging for two PyPI tools with no nixpkgs equivalent — `headroom-ai` (an LLM context-
compression proxy) and `code-context-engine` (a semantic code-indexing MCP server) — built via
[uv2nix](https://github.com/pyproject-nix/uv2nix) from a pinned `pyproject.toml` + `uv.lock`.
Consumed by a personal microVM fleet that previously installed both tools at guest-boot time via
`uvx --from <pkg> ...`, paying a cold network fetch (and, after that was cached offline, real
packaging risk — platform-tag mismatches, non-reproducible local caches) on every fresh sandbox.
This flake replaces that runtime fetch with ordinary build-once, substitute-everywhere Nix
packages.

No deep spec: this is a thin packaging wrapper (pin two versions, let uv2nix build the resolved
wheel set) with no runtime pipeline, protocol, or stateful subsystem of its own to specify — the
ADRs below cover the decisions that matter.

## Layout

| Path | Purpose |
|------|---------|
| `flake.nix` | Loads the uv workspace, builds the python package set via uv2nix + pyproject-build-systems, exposes `packages.x86_64-linux.{default,agentic-tools}` |
| `pyproject.toml` | The only "dependencies" this project has: the two pinned package versions |
| `uv.lock` | Full resolved dependency tree (118 packages), regenerated with `uv lock` |
| `.github/workflows/ci.yml` | `nix flake check` + `nix build` + `nix fmt --check` |
| `renovate.json` | Auto-bumps `flake.lock`; flags `pyproject.toml` version-pin updates (manual `uv lock` re-run required after accepting one) |

## Stack

Nix flake, [uv2nix](https://github.com/pyproject-nix/uv2nix) + [pyproject.nix](https://github.com/pyproject-nix/pyproject.nix)
+ [build-system-pkgs](https://github.com/pyproject-nix/build-system-pkgs) for the Python package
set, `nixpkgs-unstable` as the base (Python ML packaging — onnxruntime, fastembed — tends to need
newer nixpkgs than a stable branch carries).

## Build / run

```sh
nix build .#packages.x86_64-linux.default   # x86_64-linux only -- see docs/decisions/x86-64-linux-only.md
nix flake check
```

The output is one environment (`agentic-tools`) with both `headroom` and `cce` on `PATH` — see
`docs/decisions/single-combined-environment.md` for why it is not split per tool.

## Context

```mermaid
flowchart LR
    pypi[PyPI] -->|uv lock resolves| lock[uv.lock]
    lock -->|uv2nix builds| pyset[Python package set<br/>buildPythonPackage per wheel]
    pyset -->|mkVirtualEnv| tools[pkgs.agentic-tools<br/>headroom + cce on PATH]
    tools -->|flake input, nixpkgs.follows| consumer[consuming flake<br/>personal nix config]
    consumer -->|overlay| guest[microVM guest<br/>systemPackages]
```

## Decisions

See [`decisions/`](decisions/README.md) for the ADRs: why uv2nix over a hand-rolled fetch
derivation, why `x86_64-linux` only, why one combined environment instead of per-tool packages.
