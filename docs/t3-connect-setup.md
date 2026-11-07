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

The delegator is the T3 server of your own app. It links to a guest, so the guest shows up in the app with no
pairing click. `t3-link-vm` does the linking. Install it in either of two ways.

```nix
# home-manager
imports = [ inputs.agent-env.homeModules.t3-connect-delegator ];
nixpkgs.overlays = [ inputs.agent-env.overlays.default ];     # provides pkgs.t3-server, the default CLI
t3Connect.delegator.enable = true;
# t3Connect.delegator.package = <a t3 CLI built for the app's version>;

# without home-manager: install packages.<system>.t3-link-vm; set T3_BIN to pick another CLI
```

### Before the first link

| # | Requirement | How to check |
|---|---|---|
| 1 | The app is running. The script reads the app's version from `<base>/userdata/server-runtime.json` (`<base>` is `~/.t3` unless the app uses another directory; pass it with `--base-dir`). | `jq -r .serverVersion <base>/userdata/server-runtime.json` prints a version |
| 2 | The `t3` CLI has the same version as the app's server. | `t3 --version` prints `t3 v<that version>` |
| 3 | The beta flag for linked environments is on in the app. The guest turns its own flag on at start. | the app's settings |
| 4 | The guest is up: joined to the mesh and `t3-serve` is active. | `headscale nodes list`, or `systemctl is-active t3-serve` on the guest |
| 5 | Non-interactive ssh works to the guest as `t3Connect.user`. The script uses `BatchMode`, so an unknown host key or a password prompt fails. Log in once by hand to accept the host key. | `ssh -o BatchMode=yes <target> true` exits 0 |
| 6 | You know the guest's mesh IPv6 address. | `tailscale ip -6 <node name>` |

### Link a guest

1. Run `t3-link-vm <ssh-target> "http://[<guest ipv6>]:3773"`.
2. The script does these steps in order and stops at the first failure:
   1. It compares the CLI version with the app's `serverVersion`.
   2. It runs `ssh -o BatchMode=yes -- <ssh-target> t3-pair 5m delegator` and reads the code from the output.
   3. It accepts the code only if the output is one line of 6 to 128 characters from `A-Z a-z 0-9 _ -`.
   4. It runs `t3 environment link <url> --pairing-code <code> --access <mode> --base-dir <base>`.
   5. It prints the result with the code replaced by `<code>`, and exits with the link command's status.
3. Check the link: `t3 environment list --base-dir <base>` shows the guest, and the app lists it under linked environments.

Options: `--access MODE` (`read-only`, `approval-required`, `auto-accept-edits`, `auto`, `full-access`; default
`full-access`), `--base-dir DIR` (default `~/.t3`), `--force` (go on when the versions cannot be compared; a
version mismatch is still refused), `--` (end of options, so a target that starts with a dash is a host).
`T3_BIN` overrides the CLI path.

The default is `full-access` on purpose. The sandbox is the isolation boundary and runs without a person to
approve. A session launched with a mode above the link's mode is refused (`runtime_mode_escalation_denied`).
Link only guests you accept being driven without approvals.

The pairing code is one-time and valid for 5 minutes. The CLI takes it only as an argument, so it shows in the
process list of the delegator for the length of the link call. The script never prints it.

### Remove a link

Run `t3-unlink-vm <id|label|url>` (`--base-dir DIR`, `--force` as for `t3-link-vm`).

1. The script checks the CLI version as `t3-link-vm` does.
2. It reads `t3 environment list --json` and selects the entries whose id, label or URL equals the argument.
   The match is exact, never a pattern.
3. It stops when none or more than one entry matches. The error for several lists their ids; pass one id.
4. It runs `t3 environment unlink <id> --base-dir <base>`, prints the result and exits with its status.

This removes only the delegator's entry. The guest, its mesh node and its secrets stay. The guest keeps the
session it issued for the link until you revoke it in the guest's Connections. A guest that went away stays
listed as offline until you unlink it.

### Errors

| Message | Cause and fix |
|---|---|
| `the t3 CLI is X but the delegator is Y; use a CLI built for Y` | Set `t3Connect.delegator.package` or `T3_BIN` to a CLI of version Y. |
| `cannot compare versions: no serverVersion in …/server-runtime.json (is the delegator running?)` | Start the app. Use `--force` only when you know the versions match. |
| `could not mint a code on <target>` | The ssh step failed. Run `ssh -o BatchMode=yes <target> true`: check the key, the host key, the user and that the guest is up. |
| `<target> did not return a pairing code` | The output was not one plain line. A login banner or an ssh warning is the usual cause. Remove a server banner with `Banner none` in the guest's sshd config. Silence ssh's own warnings with `LogLevel ERROR` in the client's ssh config entry for the host. |
| `t3-pair: run as <user> (ssh in as that user)` | The ssh user is not `t3Connect.user`. |
| `t3-pair: no code (is t3-serve running, and are you the <user> user?)` | The server has not started: check that the host wrote `.ready` and that `t3-serve` is active. |
| `t3-unlink-vm: no linked environment matches '<name>'` | Run `t3 environment list --base-dir <base>` and use an id, the exact label or the exact URL. |
| `t3-unlink-vm: '<name>' matches N environments; use one id:` | Several links share the label. Pass one of the listed ids. |
| the link is refused for the URL | Use the guest's tailnet IPv6 address in `http://[…]:3773`. Plain http is accepted only for loopback, `.ts.net` names and `fd7a:115c:a1e0::/48`. |

## 5. Check the setup

| Check | Command | Expected |
|---|---|---|
| host survives a reboot | compare `readlink /nix/var/nix/profiles/system` and `readlink /run/current-system` | the same store path |
| guest joined | `headscale nodes list` | `sandbox-…` online with `tag:t3` |
| server up | on the guest: `systemctl is-active t3-serve` | `active` |
| port scope | from a non-mesh machine: connect to the guest on 3773 | refused or timed out |
| link | `t3 environment list --base-dir <base>` | the guest listed |
| unlink | `t3-unlink-vm <label>`, then the same list | the guest no longer listed |
| mode | the link line shows `full-access` | yes |

Nothing removes a link when a guest goes away. Remove it with `t3-unlink-vm`.

## 6. Sandy guests (`t3-sandy`)

A guest started by `sandy run` has no mesh, no ssh and no `t3-pair`. `t3-sandy` runs the whole life of such a
guest from the machine with the T3 app: start, link, hold, unlink. It is `packages.<system>.t3-sandy`.
The sandy-side scripts `start.sh` and `guest.sh` belong to the sandy side and are not in this repo. A start needs
`--start-script` to name them.

```
t3-sandy --start-script DIR [--host ws01] [--sandy-dir '$HOME/sandy-b7'] [--base-dir ~/.t3] [--access full-access] \
         [--job-timeout 604800] [--ready-timeout 300] [--no-preflight] [--force] [--reap-only | --no-reap]
```

| Step | What happens |
|---|---|
| 0 | It unlinks the entries of earlier runs whose job has ended (see "Leftovers"). |
| 1 | It checks the CLI version as `t3-link-vm` does. |
| 2 | It checks `~/.config/sandy/trust-roots` on the sandy host (see "Preflight"). It uploads `guest.sh` and `start.sh` from `--start-script` (a directory, or the path of `start.sh`) and runs `start.sh` over `ssh -t`. `start.sh` asks for the sudo password and starts the guest as the unit `sandbox-<6 hex>`. |
| 3 | It finds the new record in `~/.sandy/jobs` on the sandy host. |
| 4 | The guest starts `t3 serve`, mints a one-time code and publishes it. The wrapper fetches it from the guest's neighbour address on `sbr0`. |
| 5 | It opens `ssh -N -L 127.0.0.1:<port>:<guest>:3773` and waits until the guest answers on `http://localhost:<port>`. |
| 6 | It runs `t3 environment link http://localhost:<port> --pairing-code <code> --access <mode>` and records the environment id and job id in `~/.local/state/t3-sandy/`. |
| 7 | It runs `sandy wait` until the job record has a result. A dropped ssh connection starts the wait again. |
| 8 | On the end of the job, on Ctrl-C, or on SIGTERM or SIGHUP, it stops the job with `sandy kill`. If the job still runs, it runs `sudo systemctl stop <unit>` over `ssh -t`. It then runs `t3-unlink-vm` for the environment and removes the tunnel. |

The exit status is 1 when an unlink fails, whatever else happened. A signal gives 130 or 143 when the unlink worked.

### Preflight

Sandy runs as root in the unit and refuses a trust-root directory that root does not own. Before the sudo prompt
the wrapper runs `find` on `~/.config/sandy/trust-roots` on the sandy host. It stops when the directory is
missing, or when it or a file inside is not owned by root or is open to group or others. Files in a 700
root-owned directory cannot be listed by the account, so only the directory is checked then. It prints this
fix and does not run it:

```
ssh -t <host> 'sudo chown -R root:root ~/.config/sandy/trust-roots && sudo chmod -R go-rwx ~/.config/sandy/trust-roots'
```

`--no-preflight` skips the check.

### The pairing code channel

The guest cannot show the code to the host before the job ends, so the sandy-side `guest.sh` publishes it. A static busybox
(`--input busybox`, built on the sandy host) serves a directory that holds one file, named by a random 128-bit
nonce that the wrapper passes in `T3_NONCE`, on port 3774. Any other path is a 404. The file is deleted and the
server stops after 5 minutes. The code is one-time and valid for 5 minutes. A local user of the sandy host who
learns the nonce, which is visible in the unit's environment, can read the code. Such a user already controls the
guest's network.

### Leftovers

An environment is a leftover when the app lists it as `unreachable` and its job record has a result. The wrapper
unlinks it at the start of every run. `--reap-only` does only this. An entry that `t3-sandy` did not create has
no state file and is never touched. A state file with no matching entry is removed.

### Prerequisites

1. `ssh -o BatchMode=yes <host> true` works from the Mac.
2. On the sandy host: the `sandy` binary at `<sandy-dir>/target/release/sandy`, `sandytap0` (run `sandy-net.sh up`),
   `jq`, `curl`, `nix`, and sudo for the account.
3. The `t3` CLI has the version of the app, as in section 4.

### Not verified live

Verified: the wrapper against a fake sandy host and CLI (`checks.x86_64-linux.t3-sandy`). The sandy-side scripts
have their own checks. Not verified until the first live start: that `sandy kill` works without
root, that the guest's `t3` has `auth pairing create` (the script falls back to `t3 pair`), that the sandy
host reaches port 3774 of the guest, and that `--env` reaches the guest script.
