# modules/t3-connect/link-vm.nix
# t3-link-vm: link one sandbox to the delegator (the user's own T3 server) with no click in the app.
# It mints a one-time code on the sandbox over ssh (`t3-pair`, installed by nixosModules.t3-connect)
# and hands it to `t3 environment link` on the delegator. The code never reaches the terminal.
#
# `t3` here is the delegator's own CLI: it writes into the delegator's database, so it must be the
# delegator's version. A newer database makes an older CLI warn that migrations are unknown and
# skipped; the script refuses instead.
{
  pkgs,
  t3 ? pkgs.t3-server,
}:
pkgs.writeShellApplication {
  name = "t3-link-vm";
  runtimeInputs = [
    pkgs.jq
    pkgs.gnused
    pkgs.coreutils
  ];
  text = ''
    usage() {
      echo "usage: t3-link-vm [--access MODE] [--base-dir DIR] <ssh-target> <url>" >&2
      echo "  MODE: read-only, approval-required, auto-accept-edits, auto, full-access (default)" >&2
      exit 2
    }

    # A sandbox is the isolation boundary and runs unattended, so the link is full access by default:
    # a lower mode makes a delegated full-access launch fail (runtime_mode_escalation_denied).
    access=full-access
    base="$HOME/.t3"
    while [ $# -gt 0 ]; do
      case "$1" in
        --access) access="''${2:?--access needs a value}"; shift 2 ;;
        --base-dir) base="''${2:?--base-dir needs a value}"; shift 2 ;;
        -h | --help) usage ;;
        --) shift; break ;;
        -*) echo "t3-link-vm: unknown flag $1" >&2; usage ;;
        *) break ;;
      esac
    done
    [ $# -eq 2 ] || usage
    target="$1"
    url="$2"
    t3="''${T3_BIN:-${t3}/bin/t3}"

    cli=$("$t3" --version | sed 's/^t3 v//')
    runtime="$base/userdata/server-runtime.json"
    if [ -f "$runtime" ]; then
      server=$(jq -r '.serverVersion // empty' "$runtime")
      if [ -n "$server" ] && [ "$server" != "$cli" ]; then
        echo "t3-link-vm: the t3 CLI is $cli but the delegator is $server; use a CLI built for $server" >&2
        exit 1
      fi
    else
      echo "t3-link-vm: no $runtime (the delegator is not running); cannot compare versions" >&2
    fi

    # `--` so a target that starts with a dash is a host, never an ssh option.
    code=$(ssh -- "$target" t3-pair 5m delegator) || {
      echo "t3-link-vm: could not mint a code on $target" >&2
      exit 1
    }
    [ -n "$code" ] || {
      echo "t3-link-vm: $target returned an empty code" >&2
      exit 1
    }

    # Redact with parameter expansion, not sed: a code with `/` or `&` would break a sed pattern.
    status=0
    out=$("$t3" environment link "$url" --pairing-code "$code" --access "$access" --base-dir "$base" 2>&1) \
      || status=$?
    printf '%s\n' "''${out//"$code"/<code>}"
    exit "$status"
  '';
}
