# Setting up the t3-connect layer

What to set on each machine so a T3 Code client (desktop app, browser, phone) reaches a `t3 serve` that
runs in a sandbox. The reasoning is in [`decisions/t3-connect-layer.md`](decisions/t3-connect-layer.md).
Every value below was needed in a live run; a missing one fails in the way listed.

| Machine | Role | Module |
|---|---|---|
| mesh server | Headscale (or Tailscale): tags, access rules, pre-auth keys | none, see below |
| host | runs the sandboxes | `nixosModules.t3-connect-host` (optional) |
| guest | the T3 server the client connects to | `nixosModules.t3-sandbox` |
| delegator | the machine with the T3 app | `homeModules.t3-connect-delegator` |

## 1. Mesh server

| Setting | Value | If missing |
|---|---|---|
| tag owner | `tag:t3` owned by an admin group | the join with a tagged key is refused |
| access rule | the people who use the client may reach `tag:t3` on the t3 port (3773) | the client times out |
| DNS rule | every node may reach `dns:53` | the guest cannot resolve the mesh |
| guest to guest | no rule from `tag:t3` to `tag:t3` | guests that share the tag can reach each other |
| pre-auth key | tagged `tag:t3`, ephemeral, single use, 10 minutes, minted per start | a reused or long-lived key lets a copy of the guest join |

- The guest never passes `--advertise-tags`: the tag comes from the key. A client-sent tag is refused.
- Headscale has no Serve HTTPS and no `tailscale cert`. The guest serves plain http inside the mesh. HTTPS
  is a separate piece of work.
- The delegator links over the guest's tailnet IPv6 address (`fd7a:115c:a1e0::/48`). The t3 link accepts
  plain http only for loopback, `.ts.net` names and that range, so a Headscale IPv4 address is refused.

## 2. Host (optional)

Skip this when another system gives the guests a network. Otherwise set `t3ConnectHost.enable = true`.

| Setting | Value | If missing |
|---|---|---|
| `networking.firewall.enable` | `true`, iptables backend, nftables off | the module fails evaluation |
| bridge name | not `br-*` and at most 15 characters | evaluation fails (docker hosts trust `br-*`) |
| tap names | match `t3ConnectHost.tapMatch` (default `vm-*`) | the tap does not join the bridge |
| `net.ipv4.ip_forward` | `1` (the module sets it) | guests have no internet |
| secrets directory | one directory per guest, for example `/run/secrets-host/<id>`, mode `0711` root, shared read-only into the guest as `/run/secrets` | the guest never starts |

Deploy with `switch`, not `test`. A `test` activation has no boot entry, and a reboot returns to the
previous generation: no bridge, no firewall rules, no guests.

The secrets directory lives on a tmpfs, so it is empty after a host reboot. Refill it before each guest
start: the pre-auth key is single use.

## 3. Guest

```nix
imports = [ inputs.agent-env.nixosModules.t3-sandbox ];
t3Connect.mesh.loginServer = "https://mesh.example.net";   # the only required setting
t3Connect.credentials.CLAUDE_CODE_OAUTH_TOKEN = "claude-oauth-token";   # variable -> file in secretsDir
```

| Setting | Default | Note |
|---|---|---|
| `t3Connect.user` | `sandbox.user` | the account must exist; `t3-pair` refuses other users |
| `t3Connect.bind` / `port` | `::` / `3773` | the port opens only on the mesh interface |
| `t3Connect.harnesses` | `sandbox.tools` | opencode is seeded enabled, codex follows `providers` |
| `t3Connect.providers` | none | `{ codex = false; }` seeds an instance as off; an edit in the app persists |
| `t3Connect.secretsDir` | `/run/secrets` | the files below must exist here |
| `networking.firewall.enable` | must be `true` | otherwise the module fails evaluation |

Files the host puts in the secrets directory, with the marker last:

| File | Content |
|---|---|
| `tailscale-authkey` | the single-use pre-auth key |
| `hostname` | the node name, unique per boot, for example `sandbox-<16 hex>` |
| one file per credential | named by the values of `t3Connect.credentials` |
| `.ready` | written last; a new modification time starts the join and the server |

The ready check polls every 5 seconds, because a virtiofs share gives no file events. A `.ready` left over from
the last boot starts one join with an expired key. The next injection replaces it.

## 4. Delegator (the machine with the T3 app)

| Setting | Value | If missing |
|---|---|---|
| beta flag "linked environments" | on, in the app | `t3 environment link` is refused |
| `t3` CLI version | the same as the app's server (`serverVersion` in `<base>/userdata/server-runtime.json`) | `t3-link-vm` refuses: a newer database written by an older CLI loses data |
| base directory | the app's (default `~/.t3`) | the link lands in a different database |
| ssh | key access to the guest as `t3Connect.user` over the mesh | no pairing code can be minted |
| access mode | `full-access` (the `t3-link-vm` default) | a sandbox job stops at approvals; a child mode above the link mode is denied |

Link a guest: `t3-link-vm <ssh-target> "http://[<guest ipv6>]:3773"`. The pairing code is passed on the `t3`
command line for the length of the call (the CLI takes it no other way) and lives 5 minutes.

## 5. Check the setup

| Check | Command | Expected |
|---|---|---|
| host survives a reboot | compare `readlink /nix/var/nix/profiles/system` and `readlink /run/current-system` | the same store path |
| guest joined | `headscale nodes list` | `sandbox-…` online with `tag:t3` |
| server up | on the guest: `systemctl is-active t3-serve` | `active` |
| port scope | from a non-mesh machine: connect to the guest on 3773 | refused or timed out |
| link | `t3 environment list --base-dir <base>` | the guest listed |
| mode | the link line shows `full-access` | yes |

Nothing removes a link when a guest goes away. Remove it with `t3 environment unlink`.
