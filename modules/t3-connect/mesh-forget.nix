# modules/t3-connect/mesh-forget.nix
# t3-mesh-forget: delete a stopped guest's node from the Headscale mesh, so its address and name are
# free again. A guest cannot do this itself: deleting needs admin access it must never hold, and a
# logout on shutdown would also fire on every restart of a persistent guest. So the delegator runs it
# after the guest is stopped, through the admin command in $T3_MESH_ADMIN (for example
# `ssh -J root@jump root@headscale`), which is given the `headscale ...` command to run.
#
# A node matches only on an exact `given_name` AND the tag (default tag:t3), so the humans' devices and
# servers never match. The id comes from Headscale, never from the guest, and is checked as a number
# before it reaches a command. Without --yes it only says what it would delete.
{ pkgs }:
pkgs.writeShellApplication {
  name = "t3-mesh-forget";
  runtimeInputs = [
    pkgs.jq
    pkgs.coreutils
  ];
  text = ''
    usage() {
      echo "usage: t3-mesh-forget [--yes] [--tag TAG] <hostname>   (admin command in \$T3_MESH_ADMIN)" >&2
      exit 2
    }

    yes=0
    tag="tag:t3"
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes) yes=1; shift ;;
        --tag) tag="''${2:?--tag needs a value}"; shift 2 ;;
        -h | --help) usage ;;
        --) shift; break ;;
        -*) echo "t3-mesh-forget: unknown flag $1" >&2; usage ;;
        *) break ;;
      esac
    done
    [ $# -eq 1 ] || usage
    host="$1"

    # A DNS label: it is data for jq below, and nothing but a label can name a mesh node.
    if ! [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
      echo "t3-mesh-forget: '$host' is not a DNS label (lowercase letters, digits and hyphens)" >&2
      exit 2
    fi
    if [ -z "''${T3_MESH_ADMIN:-}" ]; then
      echo "t3-mesh-forget: set T3_MESH_ADMIN to the command that reaches the Headscale host" >&2
      exit 2
    fi
    read -r -a admin <<<"$T3_MESH_ADMIN"

    list_nodes() { "''${admin[@]}" headscale nodes list -o json; }

    nodes=$(list_nodes) || {
      echo "t3-mesh-forget: could not list the mesh nodes" >&2
      exit 1
    }
    # Whole-string match on the name and membership of the tag: the name is data, never a pattern.
    match=$(jq -c --arg n "$host" --arg t "$tag" \
      '.[] | select(.given_name == $n and ((.tags // []) | index($t))) | {id, given_name, online}' <<<"$nodes")
    count=$(grep -c . <<<"$match" || true)
    if [ "$count" -eq 0 ]; then
      echo "t3-mesh-forget: no node named '$host' with $tag (nothing to forget)" >&2
      exit 1
    elif [ "$count" -gt 1 ]; then
      echo "t3-mesh-forget: '$host' matches $count nodes; delete one by id by hand:" >&2
      jq -r '"  id \(.id)"' <<<"$match" >&2
      exit 1
    fi

    id=$(jq -r '.id' <<<"$match")
    online=$(jq -r '.online // false' <<<"$match")
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
      echo "t3-mesh-forget: the mesh returned an id that is not a number" >&2
      exit 1
    fi
    if [ "$online" = true ]; then
      echo "t3-mesh-forget: '$host' (id $id) is online; stop the guest first" >&2
      exit 1
    fi

    if [ "$yes" -ne 1 ]; then
      echo "would delete id $id ($host, $tag); run again with --yes"
      exit 0
    fi

    # The node may have rejoined since the first look: check again right before the delete.
    now=$(list_nodes | jq -r --argjson id "$id" '.[] | select(.id == $id) | .online // false') || now=
    if [ "$now" = true ]; then
      echo "t3-mesh-forget: '$host' (id $id) came online; stop the guest first" >&2
      exit 1
    fi

    "''${admin[@]}" headscale nodes delete -i "$id" --force || {
      echo "t3-mesh-forget: the delete of id $id failed" >&2
      exit 1
    }
    if list_nodes | jq -e --argjson id "$id" 'any(.[]; .id == $id)' >/dev/null; then
      echo "t3-mesh-forget: id $id is still listed after the delete" >&2
      exit 1
    fi
    echo "deleted id $id ($host)"
  '';
}
