#!/usr/bin/env bash
# Runs on the sandy host as the sandy user (one sudo prompt): build the guest's helper tools and start
# the guest as a transient unit. Mirrors the sandy host's own launcher, with this guest script and a
# static busybox (its httpd publishes the pairing code) as inputs.
# Needs: UNIT, NONCE, JOB_TIMEOUT, SANDY_DIR in the environment, and guest.sh next to this file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${UNIT:?}" "${NONCE:?}" "${JOB_TIMEOUT:?}" "${SANDY_DIR:?}"

tools="$(nix build nixpkgs#qemu nixpkgs#virtiofsd nixpkgs#nftables nixpkgs#iptables nixpkgs#iproute2 --no-link --print-out-paths | sed 's|$|/bin|' | tr '\n' ':')"
bb="$(nix build nixpkgs#pkgsStatic.busybox --no-link --print-out-paths)/bin/busybox"
ip link show sandytap0 >/dev/null 2>&1 || { echo "sandytap0 missing: run sandy-net.sh up first" >&2; exit 1; }

sudo systemd-run --unit="$UNIT" --collect \
  --setenv=HOME="$HOME" \
  --setenv=PATH="${tools}${SANDY_DIR}/target/release:/run/current-system/sw/bin" \
  --setenv=SANDY_NETWORK=nic --setenv=SANDY_TAP=sandytap0 \
  sandy run "$SANDY_DIR/nix/guest#topologies.x86_64-linux.qemu-t3" \
    --cpu 2 --mem 2304 --timeout "$JOB_TIMEOUT" \
    --allow 0.0.0.0/0:443 --allow 0.0.0.0/0:53 \
    --credential external-actor --cred-capability read-code \
    --input "$here/guest.sh:guest.sh" --input "$bb:busybox" \
    --env "T3_NONCE=$NONCE" \
    -- bash /run/sandy/inputs/guest.sh
