# modules/t3-connect/unlink-vm.nix
# t3-unlink-vm: forget one linked sandbox on the delegator (the user's own T3 server). It looks the
# environment up in `t3 environment list --json` by id, label or URL and runs `t3 environment unlink`.
# That removes only the delegator's entry. The sandbox keeps its own session for the link until it is
# revoked in the sandbox's Connections, and the sandbox, its mesh node and its secrets are untouched.
# `--forget-node HOST` also deletes the stopped guest's mesh node afterwards (t3-mesh-forget --yes).
# Same version rule as t3-link-vm: the CLI writes the delegator's database.
{
  pkgs,
  t3 ? pkgs.t3-server,
  meshForget ? import ./mesh-forget.nix { inherit pkgs; },
}:
pkgs.writeShellApplication {
  name = "t3-unlink-vm";
  runtimeInputs = [
    pkgs.jq
    pkgs.gnused
    pkgs.coreutils
  ];
  text = ''
    usage() {
      echo "usage: t3-unlink-vm [--base-dir DIR] [--force] [--forget-node HOST] [--] <id|label|url>" >&2
      exit 2
    }

    base="$HOME/.t3"
    force=0
    forget_node=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --base-dir) base="''${2:?--base-dir needs a value}"; shift 2 ;;
        --force) force=1; shift ;;
        --forget-node) forget_node="''${2:?--forget-node needs a hostname}"; shift 2 ;;
        -h | --help) usage ;;
        --) shift; break ;;
        -*) echo "t3-unlink-vm: unknown flag $1" >&2; usage ;;
        *) break ;;
      esac
    done
    [ $# -eq 1 ] || usage
    name="$1"
    t3="''${T3_BIN:-${t3}/bin/t3}"
    forget="''${T3_MESH_FORGET_BIN:-${meshForget}/bin/t3-mesh-forget}"

    ${import ./cli-version.nix "t3-unlink-vm"}

    list=$("$t3" environment list --json --base-dir "$base") || {
      echo "t3-unlink-vm: could not list the linked environments" >&2
      exit 1
    }
    # Whole-string matches only: the name is data for jq, never a pattern.
    ids=$(jq -r --arg n "$name" '.[] | select(.environmentId == $n or .label == $n or (.urls | index($n))) | .environmentId' <<<"$list")
    count=$(grep -c . <<<"$ids" || true)
    if [ "$count" -eq 0 ]; then
      echo "t3-unlink-vm: no linked environment matches '$name' (see: t3 environment list)" >&2
      exit 1
    elif [ "$count" -gt 1 ]; then
      echo "t3-unlink-vm: '$name' matches $count environments; use one id:" >&2
      echo "  ''${ids//$'\n'/$'\n'  }" >&2
      exit 1
    fi

    status=0
    "$t3" environment unlink "$ids" --base-dir "$base" || status=$?
    [ "$status" -ne 0 ] || echo "t3-unlink-vm: forgot $ids here; revoke its session in that environment's Connections to end it there too" >&2
    if [ "$status" -eq 0 ] && [ -n "$forget_node" ]; then
      "$forget" --yes "$forget_node" || {
        echo "t3-unlink-vm: unlinked $ids, but the mesh node '$forget_node' was not deleted" >&2
        status=1
      }
    fi
    exit "$status"
  '';
}
