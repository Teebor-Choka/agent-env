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

### The t3-connect layer

A switchable layer for reaching a sandbox from a T3 Code client (the desktop app, a browser, a phone) over your own
mesh, with no per-sandbox click. Off by default: `t3Connect.enable = false` adds nothing. The reasoning and the
specification are in [`docs/decisions/t3-connect-layer.md`](docs/decisions/t3-connect-layer.md).

```nix
# 1. the sandbox: runs `t3 serve`, joins the mesh, seeds the t3 settings
imports = [ inputs.agent-env.nixosModules.t3-connect ];
t3Connect = {
  enable = true;
  user = "me";                                              # an existing ordinary account
  harnesses = [ "claude" "opencode" ];                      # opencode is seeded enabled; t3 leaves it off
  credentials.CLAUDE_CODE_OAUTH_TOKEN = "claude-oauth-token";   # env var -> file in secretsDir (/run/secrets)
  providers.codex = false;                                  # seeded only when absent, so app edits persist
  mesh = { enable = true; loginServer = "https://mesh.example.net"; };
};

# 2. the host, optional: a bridge, NAT and a firewall that give guests public egress only
imports = [ inputs.agent-env.nixosModules.t3-connect-host ];
t3ConnectHost.enable = true;                                # taps named vm-* join the bridge t3br0

# 3. the machine that runs the T3 app (home-manager): links a sandbox to it
imports = [ inputs.agent-env.homeModules.t3-connect-delegator ];
t3Connect.delegator = { enable = true; package = <the t3 CLI matching the app>; };
#   t3-link-vm <ssh-target> "http://[<node ipv6>]:3773"       # full access by default
#   t3-unlink-vm <id|label|url>                               # forget it again
#   t3-run-vm --host H --guest ADDR --start-script DIR        # VM without a mesh: start, link, hold, unlink
```

What to set on each machine (mesh server, host, guest, delegator) and how to check it:
[`docs/t3-connect-setup.md`](docs/t3-connect-setup.md).

#### One module for the whole guest

`nixosModules.t3-sandbox` is the sandbox account, the harnesses and the t3 layer in one import. It sets
`t3Connect.enable`, takes the t3 user and harnesses from `sandbox.user` and `sandbox.tools`, and turns the mesh
on. The only setting you must add is the mesh login server:

```nix
imports = [ inputs.agent-env.nixosModules.t3-sandbox ];
t3Connect.mesh.loginServer = "https://mesh.example.net";
# optional: sandbox.user = "dev"; sandbox.tools = [ "claude" "opencode" ];
#           t3Connect.credentials.CLAUDE_CODE_OAUTH_TOKEN = "claude-oauth-token";
```

Import it instead of `sandbox` and `t3-connect`, not as well: both declare the same options. A builder that
takes one module name and passes no options (for example `sandy run --attr`) cannot set the login server, so
wrap `t3-sandbox` in a module of your own that sets it, and pass that.

| Machine | Module |
|---|---|
| the guest (the server your phone or app connects to) | `nixosModules.t3-sandbox`, or `sandbox` plus `t3-connect` for finer control |
| an image whose builder starts `t3 serve` itself, such as sandy (user, t3, ready probe, git credential helper; no service or mesh) | `nixosModules.t3-guest` |
| the host that runs the guests (optional) | `nixosModules.t3-connect-host` |
| the machine that runs the T3 app | `homeModules.t3-connect-delegator` |

The host fills the secrets directory before boot and writes the marker `.ready` last; how it is shared
(virtiofs, a disk) is the builder's business. The overlay adds `pkgs.t3-server` (headless `t3 serve`). A guest
that is linked needs the mesh IPv6 address: a peer link refuses plain http except for loopback and the tailnet
range `fd7a:115c:a1e0::/48`. Checks: `nix flake check --all-systems` evaluates the guest and host modules and
runs the `t3-link-vm` and `t3-unlink-vm` suites; the rules are proven in two VMs with `nix build .#t3-connect-host-test -L` on a KVM host.
From macOS with a Linux builder, add `--max-jobs 0`: `preferLocalBuild` derivations (`writeText`) otherwise run on the Mac and fail with `Undefined error: 0`.

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
