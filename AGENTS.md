# AGENTS.md

The agentic environment for agent sandboxes: Nix packaging (via
[uv2nix](https://github.com/pyproject-nix/uv2nix)) for the PyPI tool `headroom-ai`, plus the
NixOS and nix-darwin modules that configure the harnesses around it. See [`docs/overview.md`](docs/overview.md)
for the full writeup and [`docs/decisions/`](docs/decisions/) for why this exists and why it is
built the way it is.

## Layout

| Path | Purpose |
|------|---------|
| `flake.nix` | uv2nix wiring: loads the workspace, builds the python package set, exposes `packages.{aarch64-linux,x86_64-linux}.{default,agentic-tools}` |
| `modules/agentic.nix` | The environment module, exported as `nixosModules.agentic` and `darwinModules.agentic` (platform fixed per export) |
| `modules/sandbox.nix` | `nixosModules.sandbox`: the thin sandbox (harnesses + system-level config + a DynamicUser proxy, no home-manager) |
| `modules/shared.nix` | Proxy flags and MCP wrapper shared by `agentic.nix` and `sandbox.nix` |
| `tests/sandbox-boot.sh` | Live boot test, `nix run .#test-sandbox` (needs sandy; never run in CI) |
| `modules/home/` | home-manager modules: `home.agentPlugins`, `home.skillLink`, `home.swePlugin` |
| `tests/` | `agent-plugins-suite.sh` and its fixtures, run as `checks.<system>.agent-plugins-lib` |
| `pyproject.toml` | Pins the package version (the only "dependency" this project has) |
| `uv.lock` | Full resolved dependency tree, regenerated with `uv lock` |
| `.github/workflows/ci.yml` | `nix flake check` + `nix build` + `nix fmt --check` on every push/PR |
| `renovate.json` | Bumps `flake.lock` automatically; `pyproject.toml` version pins get PRs too, but `uv lock` must be re-run by hand after accepting one |

## Build / check

```sh
nix build .#packages.x86_64-linux.default   # or aarch64-linux -- no macOS wheel for headroom-ai
nix flake check --all-systems
nix fmt
```

## Bumping a package version

1. Edit the version pin in `pyproject.toml`.
2. `uv lock` to regenerate `uv.lock`.
3. `nix build .#packages.x86_64-linux.default` (and `aarch64-linux`) to confirm it still resolves and builds.
4. Commit both files together — an `uv.lock` out of sync with `pyproject.toml` is a broken state.

## Conventions

- Conventional commits.
- Packages are Linux only, deliberately (`aarch64-linux` + `x86_64-linux`) — see
  `docs/decisions/linux-only-no-macos.md`. The modules evaluate on darwin too.
- The modules know nothing about how a sandbox is built (no microvm, share or trust options); see
  `docs/decisions/environment-modules.md`.
- One `agentic-tools` environment (headroom only since `docs/decisions/drop-code-context-engine.md`).
