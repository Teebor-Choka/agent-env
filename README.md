# agentic-pkgs

Nix packaging for agentic-tooling PyPI packages with no nixpkgs equivalent: [headroom-ai](https://pypi.org/project/headroom-ai/)
and [code-context-engine](https://pypi.org/project/code-context-engine/). Built with
[uv2nix](https://github.com/pyproject-nix/uv2nix) from a pinned `pyproject.toml` + `uv.lock`, so
both ship as real `buildPythonPackage`-based derivations instead of a runtime `uvx` fetch.

## Why this exists

Both tools were originally consumed via `uvx --from <pkg> ...` at guest-boot time in a personal
microVM fleet. That meant every fresh sandbox paid a cold network fetch (package wheels, the
embedding model) and, once fixed with offline caching, still carried real packaging risk
(platform-tag mismatches, non-reproducible local caches). This flake replaces that with ordinary
Nix packages: build once, substitute everywhere, zero runtime fetch.

`x86_64-linux` only — `headroom-ai` ships no macOS wheel (PyPI only publishes
`manylinux_2_28_x86_64` for 0.41.0), and this flake only ever needs to run where the guests that
install these tools actually run.

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

`pkgs.agentic-tools` is one environment carrying both `headroom` and `cce` on `PATH` — both tools
are always installed together wherever either is needed, so there is no per-tool split.

## Updating

- **Nix inputs** (`flake.lock`): `nix flake update`.
- **Package versions** (`pyproject.toml` + `uv.lock`): bump the version pin in `pyproject.toml`,
  then `uv lock` to regenerate the lockfile. Renovate opens PRs for the `pyproject.toml` version
  pins automatically but does not run `uv lock` itself — that step is manual.

## Development

```sh
nix flake check   # builds the package, runs nix fmt --check
nix build         # build pkgs.agentic-tools for x86_64-linux
```

See [`docs/overview.md`](docs/overview.md) for the full project writeup and
[`docs/decisions/`](docs/decisions/) for the ADRs behind the design choices here (uv2nix over a
hand-rolled FOD, why `x86_64-linux` only, why one combined environment).
