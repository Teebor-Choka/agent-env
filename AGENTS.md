# AGENTS.md

Nix packaging (via [uv2nix](https://github.com/pyproject-nix/uv2nix)) for two PyPI tools with no
nixpkgs equivalent: `headroom-ai` and `code-context-engine`. See [`docs/overview.md`](docs/overview.md)
for the full writeup and [`docs/decisions/`](docs/decisions/) for why this exists and why it is
built the way it is.

## Layout

| Path | Purpose |
|------|---------|
| `flake.nix` | uv2nix wiring: loads the workspace, builds the python package set, exposes `packages.{aarch64-linux,x86_64-linux}.{default,agentic-tools}` |
| `pyproject.toml` | Pins the two package versions (the only "dependencies" this project has) |
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
- Linux only, deliberately (`aarch64-linux` + `x86_64-linux`) — see
  `docs/decisions/linux-only-no-macos.md`.
- One combined `agentic-tools` environment, not a package per tool — see
  `docs/decisions/single-combined-environment.md`.
