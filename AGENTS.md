# AGENTS.md

The agentic environment for agent sandboxes: Nix packaging (via
[uv2nix](https://github.com/pyproject-nix/uv2nix)) for the PyPI tool `headroom-ai`, plus the
NixOS and nix-darwin modules that configure the harnesses around it. See [`docs/overview.md`](docs/overview.md)
for the full writeup and [`docs/decisions/`](docs/decisions/) for why this exists and why it is
built the way it is.

## Layout

| Path | Purpose |
|------|---------|
| `flake.nix` | uv2nix wiring: loads the workspace, builds the python package set, exposes `packages.{aarch64-linux,x86_64-linux}.{default,agentic-tools,t3-link-vm,t3-unlink-vm,t3-run-vm}` and `packages.x86_64-linux.t3-connect-host-test` |
| `modules/agentic.nix` | The environment module, exported as `nixosModules.agentic` and `darwinModules.agentic` (platform fixed per export) |
| `modules/sandbox.nix` | `nixosModules.sandbox`: a basic `user@sandbox` (an ordinary account with a minimal home, the chosen harnesses, a DynamicUser proxy; no home-manager) |
| `modules/t3-connect/` | The t3-connect layer (`docs/decisions/t3-connect-layer.md`): `guest.nix` (`nixosModules.t3-connect`), `host.nix` (`nixosModules.t3-connect-host`, the one module that knows about a bridge and a firewall), `delegator.nix` (`homeModules.t3-connect-delegator`), `sandbox.nix` (`nixosModules.t3-sandbox`, the one-import guest: `sandbox` plus `t3-connect`), `link-vm.nix` (`t3-link-vm`) |
| `modules/shared.nix` | Proxy flags and MCP wrapper shared by `agentic.nix` and `sandbox.nix` |
| `tests/sandbox-boot.sh` | Live boot test, `nix run .#test-sandbox` (needs sandy; never run in CI) |
| `modules/home/` | home-manager modules: `home.agentPlugins`, `home.skillLink`, `home.swePlugin` |
| `tests/` | `agent-plugins-suite.sh` and its fixtures, run as `checks.<system>.agent-plugins-lib` |
| `tests/t3-link-vm.sh`, `tests/t3-unlink-vm.sh`, `tests/t3-connect-host-vm.nix` | the `t3-link-vm` and `t3-unlink-vm` suites (`checks.<system>.t3-link-vm`) and the two-VM proof of the host rules (`packages.x86_64-linux.t3-connect-host-test`, needs KVM, never in CI) |
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
  `docs/decisions/environment-modules.md`. The one exception is `nixosModules.t3-connect-host` (a bridge and
  a firewall, still no microvm, qemu or sandy); see `docs/decisions/t3-connect-layer.md`.
- One `agentic-tools` environment (headroom only since `docs/decisions/drop-code-context-engine.md`).
