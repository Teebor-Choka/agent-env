# agentic-pkgs

Nix packaging for [headroom-ai](https://pypi.org/project/headroom-ai/), an agentic-tooling PyPI package
with no nixpkgs equivalent. Built with
[uv2nix](https://github.com/pyproject-nix/uv2nix) from a pinned `pyproject.toml` + `uv.lock`, so
it ships as real `buildPythonPackage`-based derivations instead of a runtime `uvx` fetch.

## Why this exists

The tool was originally consumed via `uvx --from <pkg> ...` at guest-boot time in a personal
microVM fleet. That meant every fresh sandbox paid a cold network fetch (package wheels) and, once fixed with offline caching, still carried real packaging risk
(platform-tag mismatches, non-reproducible local caches). This flake replaces that with ordinary
Nix packages: build once, substitute everywhere, zero runtime fetch.

Linux only (`aarch64-linux` + `x86_64-linux`) — `headroom-ai` ships no macOS wheel (PyPI only
publishes `manylinux_2_28_{x86_64,aarch64}` for 0.41.0), and this flake only ever needs to run
where the guests that install these tools actually run.

## Usage

```nix
# in a consuming flake
agentic-pkgs.url = "github:Teebor-Choka/agentic-pkgs";
agentic-pkgs.inputs.nixpkgs.follows = "nixpkgs"; # or nixpkgs-unstable
```

```nix
# in an overlay
final: prev: {
  agentic-tools = inputs.agentic-pkgs.packages.${prev.stdenv.hostPlatform.system}.agentic-tools;
}
```

`pkgs.agentic-tools` is one environment carrying `headroom` on `PATH`.

## Updating

- **Nix inputs** (`flake.lock`): `nix flake update`.
- **Package versions** (`pyproject.toml` + `uv.lock`): bump the version pin in `pyproject.toml`,
  then `uv lock` to regenerate the lockfile. Renovate opens PRs for the `pyproject.toml` version
  pins automatically but does not run `uv lock` itself — that step is manual.

## Development

```sh
nix flake check --all-systems           # builds the package, runs nix fmt --check
nix build .#packages.x86_64-linux.default   # or aarch64-linux
```

See [`docs/overview.md`](docs/overview.md) for the full project writeup and
[`docs/decisions/`](docs/decisions/) for the ADRs behind the design choices here (uv2nix over a
hand-rolled FOD, why Linux only, why code-context-engine was dropped).
