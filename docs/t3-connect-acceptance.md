# Acceptance test before merging PR #9

Two setup types connect a VM to the T3 app. Test them in this order, on one VM on the mesh.

| Type | What it gives | Mechanism |
|---|---|---|
| `t3-linked` | An agent in a delegator thread drives the VM (sandbox operations), within the link's access mode. The VM does not appear in the pane. | `t3-link-vm` (mesh VM), `t3-run-vm` (VM without a mesh) |
| `t3-remote` | The VM's projects and threads appear in the app's pane. The harness uses the VM's own credentials. | The app's add-environment dialog: host and pairing code, over the mesh address |

Each check says what to run and what must happen. Stop at the first failure and record the output.

## 0. Preconditions

| # | Check | Command | Pass |
|---|---|---|---|
| 0.1 | The host is deployed with `switch`, not `test`. | `ssh <host> readlink /run/current-system` and `/run/booted-system` after a reboot | the t3 VMs come back after the reboot |
| 0.2 | The guest runs t3 0.1.6 or newer. | `ssh <guest> t3 --version` | `t3 v0.1.6` or higher |
| 0.3 | The CLI on the Mac equals the app's version. | `jq -r .serverVersion ~/.t3/userdata/server-runtime.json` and `T3_BIN=<cli> $T3_BIN --version` | the same version |
| 0.4 | The VM is on the mesh and its server answers. | `curl -s -o /dev/null -w '%{http_code}' http://[<guest ipv6>]:3773/` | a code below 500 |
| 0.5 | The guest has its own harness login. | on the guest: `claude auth status` | the VM's account, not the Mac's |
| 0.6 | The VM cannot reach another identity's VM. | from the guest: `curl -m 3 http://<other guest>:3773/` | fails |

## 1. `t3-linked`

| # | Step | Pass |
|---|---|---|
| 1.1 | `T3_BIN=<cli> t3-link-vm <ssh-target> "http://[<guest ipv6>]:3773"` | prints `Linked ... (<environment id>)`, code shown as `<code>`, exit 0 |
| 1.2 | `t3 environment list --json --base-dir ~/.t3 \| jq '.[] \| {environmentId,status,access}'` | the entry has `status: reachable`, `access: full-access` |
| 1.3 | In the app, Settings > Connections lists the entry (refresh the page once). | the entry is listed with its expiry |
| 1.4 | In a Mac thread, ask the agent to run `hostname` on the linked environment. | the output is the VM's hostname |
| 1.5 | Quit the Mac app, wait 5 minutes, reopen. | the entry is still linked and `reachable` |
| 1.6 | `t3-unlink-vm <environment id>` | exit 0; the entry is gone from `environment list` |
| 1.7 | `personal`-style links that this tool did not make are untouched. | `environment list` still shows them |
| 1.8 | For a VM without a mesh: `t3-run-vm --host <h> --bridge <dev> --start-script <dir>`, then Ctrl-C. | linked while running; after Ctrl-C the entry is gone, the unit is not active, exit 0 |
| 1.9 | `kill -9` that wrapper, then `t3-run-vm --host <h> --reap-only` after the unit has stopped. | the entry is unlinked, a second run does nothing |

Record the revoke step: the guest keeps the session that the link created until you revoke it in the guest's
Connections.

## 2. `t3-remote`

| # | Step | Pass |
|---|---|---|
| 2.1 | On the guest: `t3-pair 5m remote` (or `t3 auth pairing create --ttl 5m --label remote`) | one line with a code |
| 2.2 | In the app, add an environment: host `http://[<guest ipv6>]:3773`, the code. Approve by hand if the app asks. | "Backend added"; the VM shows in the pane |
| 2.3 | Open a project on the VM and start a thread with the Claude harness. | the thread runs; `claude auth status` on the guest shows the VM's account |
| 2.4 | Start a long task in the thread, quit the Mac app, wait for the task to finish, reopen. | the thread shows the finished turn |
| 2.5 | Quit the app and shut the Mac down (or sleep it) during a turn. | the turn finishes on the VM; the thread has the result after reconnect |
| 2.6 | Restart the app. | the environment reconnects without a new code |
| 2.7 | On the guest, revoke the session: `t3 auth session` list, then revoke. | the app loses access and asks for a new code |
| 2.8 | The phone: pair with the same server by QR or code, then repeat 2.4 with the Mac off. | the phone sees the thread |

Link (stage 1) and remote (stage 2) need one pairing code each. Both can exist for one VM at once; check this in
2.2 by leaving 1.1 linked.

## Out of scope here

HTTPS for guests, key expiry of tagged nodes, secrets surviving a host reboot, and the Headscale ACL rules in the
infra repo.
