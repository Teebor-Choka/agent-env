---
title: The t3-connect layer: a switchable setup for reaching a sandbox from T3 Code
status: proposed
project: agent-env
updated: 2026-11-06
---

**Context.** A T3 Code client (the desktop app, a browser, a phone) reaches an agent sandbox when the
sandbox runs `t3 serve`, joins the user's own mesh, and the client's server links to it. The setup
was first built by hand in a private NixOS config and proved live:
join, serve, a pairing credential read from the server output, and `t3 environment link` over the
tailnet IPv6 address. Its parts are generic, and several are traps that cost hours: a path unit that
never fires on virtiofs, `tailscale up` refusing without `--reset`, a refused client-sent tag, a
beta flag that must be on at both ends, and provider instances that must exist in the settings.

**Decision.** Add a layer named `t3-connect`, off by default, with three exports and a package:

| Export | What it does |
|---|---|
| `overlays.default` gains `t3-server` | headless `t3 serve` with the harness CLIs on its PATH; the desktop binary is removed on Linux only |
| `nixosModules.t3-connect` | guest side: the `t3-serve` unit, credentials, ready poller, mesh join, settings seed (linked environments, provider instances), firewall on the mesh interface |
| `nixosModules.t3-connect-host` | host side, optional: a bridge, NAT and a firewall that give a guest public egress only |
| `homeModules.t3-connect-delegator` | the delegator's side: a pinned `t3` CLI and `t3-link` and `t3-pair` helpers |

`t3Connect.enable = false` adds nothing to the system. Each sub-layer has its own switch
(`mesh.enable`, `linkedEnvironments`, `providers`). Every non-obvious setting carries a comment that
names the failure it prevents.

**Amends** [the environment modules live here](environment-modules.md), which says the modules know
nothing about how a sandbox is built. The guest module still holds to that: it names a secrets
directory and a marker, never a hypervisor, a share or a trust option. The host module is the
exception and is a separate export that a guest never imports. It knows about a bridge and a
firewall, not about microvm.nix, qemu or sandy: the tap pattern, address and ranges are options.

**Specification.**

Valid inputs
- `t3Connect.user` names an existing ordinary account. `port` is a TCP port.
- `credentials` maps an environment variable to a file name in `secretsDir`.
- `providers` maps a t3 driver name to a bool. A harness in `harnesses` that t3 does not enable by
  default (opencode) is seeded enabled unless `providers` says otherwise.
- `mesh.loginServer` is an https URL. The join key is read from `secretsDir/tailscale-authkey`.
- The host module needs a bridge name that does not start with `br-` (NixOS trusts `br-+` for input).

Expected outputs
- Enabled: `t3-serve` serves on `bind` (default `::`) and `port`, with each credential exported from
  `LoadCredential`; `t3-ready` starts the mesh join and the server when the marker's mtime changes;
  the settings seed holds `linkedEnvironmentsEnabled = true` and the provider instances, written
  only where absent so edits made in the app persist; the port is open on the mesh interface only.
- Disabled: no unit, timer, firewall rule, user or package is added.

Failure definition
- A missing credential file fails `t3-serve` at start with the file name; the unit retries.
- A missing join key leaves the guest off the mesh and `t3-serve` still starts (the join is `after`,
  not `requires`).
- An invalid option (a bridge named `br-*`, a bind that is not an address) fails evaluation with an
  assertion that names the option.

Performance and scale
- One server per guest. The poller checks one file every `ready.pollInterval` (default 5 s).

Dependency behaviour
- Needs `services.tailscale` from nixpkgs for the mesh join, `jq` for the seed, and a coordination
  server (Headscale or Tailscale) that accepts a tag-owned pre-auth key. A client-sent tag is
  never passed: the tag rides on the key.
- The guest needs a secrets directory that a host fills before boot and marks with `.ready` last.
  How it is shared (virtiofs, 9p, a disk) is the builder's business.

AI-gap self-test: a build that passes all checks but misbehaves would most likely mis-order the
join and the server (the node name applied after the server starts), seed a provider the user
disabled, or open the port on every interface. The checks assert each.

**Consequences.** A consumer flake imports the layer in place of its own units and its built guest
paths change only by the unit text. The delegator helper runs on darwin, so its module is evaluated
there even though the packages stay Linux only (see [linux-only](linux-only-no-macos.md)).

**Set aside.** Putting the host network in sandy only (sandy's own backend covers that case; this module is
for NixOS hosts). Persisting the Tailscale node identity on the guest's disk: every boot is a new
node, named by the injector, so no disk is assumed.
