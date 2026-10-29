#!/usr/bin/env bash
# Live acceptance for nixosModules.sandbox: boot it in a sandy VM and check the environment from
# inside the guest. Needs a hypervisor, so it is NOT run in CI; run it before every bump.
#   nix run .#test-sandbox                 uses `sandy` and `vfkit` from PATH (or $SANDY)
#   nix run .#test-sandbox -- <flake dir>  test another checkout (default: this flake)
set -uo pipefail

flake=${1:-$PWD}
sandy=${SANDY:-sandy}
command -v "$sandy" >/dev/null || { echo "sandy not found (set SANDY=/path/to/sandy)" >&2; exit 2; }

fail=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

run_in_guest() { # script...: run it as the job in a fresh sandbox VM
  "$sandy" run --flake "path:$flake" --kind nixos-module --attr sandbox -- sh -c "$1" 2>&1
}

# Everything the sandbox promises, checked from inside one boot: the proxy answers, and the
# harnesses are on PATH.
guest_script='
for i in $(seq 60); do curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null && break; sleep 1; done
curl -fsS -m2 http://127.0.0.1:8787/health >/dev/null || { echo "no headroom"; exit 10; }
command -v claude >/dev/null || { echo "no claude"; exit 11; }
exit 0'
if out=$(run_in_guest "$guest_script"); then
  pass "sandbox boots; headroom answers /health; claude is on PATH"
else
  bad "sandbox boots; headroom answers /health; claude is on PATH"
  echo "$out" | tail -8
fi

# Negative control: the same guest must fail a check that cannot pass, so a green run above is
# not a vacuous pass (an exit code that never propagates would look identical).
if run_in_guest 'curl -fsS -m2 http://127.0.0.1:9/health' >/dev/null; then
  bad "negative control fails inside the guest"
else
  pass "negative control fails inside the guest"
fi

exit $fail
