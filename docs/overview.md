---
title: agentic-pkgs
kind: overview
project: agentic-pkgs
updated: 2026-10-21
---

## Purpose

The agentic environment for agent sandboxes: Nix packaging for `headroom-ai` (an LLM context-compression proxy), a PyPI tool with no nixpkgs
equivalent, built via
[uv2nix](https://github.com/pyproject-nix/uv2nix) from a pinned `pyproject.toml` + `uv.lock`.
Consumed by a personal microVM fleet that previously installed it at guest-boot time via
`uvx --from <pkg> ...`, paying a cold network fetch (and, after that was cached offline, real
packaging risk — platform-tag mismatches, non-reproducible local caches) on every fresh sandbox.
This flake replaces that runtime fetch with ordinary build-once, substitute-everywhere Nix
packages.

The same flake also ships the modules that define what runs inside an agent sandbox (harnesses,
their settings, MCP wiring, compression routing, plugin and skill delivery), with no knowledge of
how the sandbox is built. See [`decisions/environment-modules.md`](decisions/environment-modules.md).

No deep spec: the package side is a thin packaging wrapper (pin one version, let uv2nix build the resolved
wheel set) with no runtime pipeline, protocol, or stateful subsystem of its own to specify — the
ADRs below cover the decisions that matter.

## Layout

| Path | Purpose |
|------|---------|
| `flake.nix` | Loads the uv workspace, builds the python package set via uv2nix + pyproject-build-systems, exposes `packages.{aarch64-linux,x86_64-linux}.{default,agentic-tools}` |
| `modules/agentic.nix` | `nixosModules.agentic` and `darwinModules.agentic`: harness packages and settings, sessions, extensions, headroom service and shell routing |
| `modules/home/` | home-manager modules for plugin and skill delivery (`home.agentPlugins`, `home.skillLink`, `home.swePlugin`) |
| `tests/` | the plugin-normalizer suite and fixtures |
| `pyproject.toml` | The only "dependency" this project has: the pinned headroom-ai version |
| `uv.lock` | Full resolved dependency tree (101 packages), regenerated with `uv lock` |
| `.github/workflows/ci.yml` | `nix flake check` + `nix build` + `nix fmt --check` |
| `renovate.json` | Auto-bumps `flake.lock`; flags `pyproject.toml` version-pin updates (manual `uv lock` re-run required after accepting one) |

## Stack

Nix flake, [uv2nix](https://github.com/pyproject-nix/uv2nix) + [pyproject.nix](https://github.com/pyproject-nix/pyproject.nix)
+ [build-system-pkgs](https://github.com/pyproject-nix/build-system-pkgs) for the Python package
set, `nixpkgs-unstable` as the base (Python ML packaging — onnxruntime — tends to need
newer nixpkgs than a stable branch carries).

## Build / run

```sh
nix build .#packages.x86_64-linux.default   # or aarch64-linux -- see docs/decisions/linux-only-no-macos.md
nix flake check --all-systems
```

The output is one environment (`agentic-tools`) with `headroom` on `PATH`.

## Context

```mermaid
flowchart LR
    pypi[PyPI] -->|uv lock resolves| lock[uv.lock]
    lock -->|uv2nix builds| pyset[Python package set<br/>buildPythonPackage per wheel]
    pyset -->|mkVirtualEnv| tools[pkgs.agentic-tools<br/>headroom on PATH]
    tools -->|overlays.default| env[nixosModules.agentic<br/>darwinModules.agentic]
    env -->|flake input| consumer[consuming flake<br/>sandbox builder + personal values]
    consumer --> guest[microVM, container or workstation]
```

## Decisions

See [`decisions/`](decisions/README.md) for the ADRs: why uv2nix over a hand-rolled fetch
derivation, why Linux only, why code-context-engine was dropped, and why the environment lives
here and not with the sandbox builder.
