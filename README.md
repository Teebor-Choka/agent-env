# agent-env

The agentic environment for an agent sandbox, as Nix: the [headroom-ai](https://pypi.org/project/headroom-ai/) package, plus the NixOS and nix-darwin modules that set up
the harnesses (claude-code, opencode, codex, omp) around it. headroom has no nixpkgs equivalent; it is built with
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
agent-env.url = "github:Teebor-Choka/agent-env";
agent-env.inputs.nixpkgs.follows = "nixpkgs";
agent-env.inputs.nixpkgs-unstable.follows = "nixpkgs-unstable";   # source of codebase-memory-mcp and omp
```

```nix
# a NixOS guest, container or workstation (needs the home-manager NixOS module)
imports = [ inputs.agent-env.nixosModules.agentic ];   # darwinModules.agentic on nix-darwin
agentic = {
  enable = true;
  user = "me";
  tools = [ "claude" "opencode" "codex" ];
  compression = true;   # local headroom proxy; Claude is routed through it when it listens
};
```

`nixosModules.sandbox` is a basic `user@sandbox` for a bare guest such as a sandy VM: one ordinary account
(`sandbox.user`, default `user`) with a minimal home, the harnesses you pick (`sandbox.tools`, default
`[ "claude" ]`), a few utilities (git, curl, jq, ripgrep), and the compression proxy as a `DynamicUser`
service. Each harness's config sits in the home as plain, user-owned, writable files (onboarding done, the
code-graph MCP server registered, telemetry and update checks off), written once with no home-manager. No
model or provider is set. sandy runs the job as root, so run it as the user:
`sandy run --flake github:Teebor-Choka/agent-env --kind nixos-module --attr sandbox -- runuser -u user -- <cmd>`.
Give the guest at least 2048 MiB (`sandy run --mem 2048`): the proxy alone holds about 240 MB and sandy's 512 MiB default
lets the kernel OOM-kill it as soon as a harness runs. The proxy also sets `LITELLM_LOCAL_MODEL_COST_MAP`, so a
guest without network does not wait on a GitHub fetch at start. The live boot test is `nix run .#test-sandbox`
(needs sandy and a hypervisor; boots the default sandbox and an all-tools one; not in CI; `SANDBOX_MEM` overrides the memory).

The module has no VM knowledge. It adds `overlays.default` (`agentic-tools`, `codebase-memory-mcp`,
`omp`) and the home-manager modules `home.agentPlugins`, `home.skillLink` and `home.swePlugin`.
Where session state and staged host extensions live is `agentic.sessionsDir` and
`agentic.extensionsDir`; whoever builds the sandbox provides them. `agentic.extensionsPackage`
feeds `extensions = "baked"`.

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
