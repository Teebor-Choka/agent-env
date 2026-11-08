# modules/t3-connect/link-vm.nix
# t3-link-vm: link one sandbox to the delegator (the user's own T3 server) with no click in the app.
# It mints a one-time code on the sandbox over ssh (`t3-pair`, installed by nixosModules.t3-connect)
# and hands it to `t3 environment link` on the delegator. The code never reaches the terminal.
#
# `t3` here is the delegator's own CLI: it writes into the delegator's database, so it must be the
# delegator's version. A newer database makes an older CLI warn that migrations are unknown and
# skipped; the script refuses instead. It also refuses when the versions cannot be compared (the
# delegator is not running, or its runtime file has no version) unless `--force` is given.
#
# The code is passed to `t3 environment link --pairing-code`, the only way the CLI takes it, so it
# is visible in the delegator's process list for the length of that call. It is one-time and lives
# five minutes.
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
      echo "usage: t3-link-vm [--access MODE] [--base-dir DIR] [--force] [--] <ssh-target> <url>" >&2
      echo "  MODE: read-only, approval-required, auto-accept-edits, auto, full-access (default)" >&2
      exit 2
    }

    # A sandbox is the isolation boundary and runs unattended, so the link is full access by default:
    # a lower mode makes a delegated full-access launch fail (runtime_mode_escalation_denied).
    access=full-access
    base="$HOME/.t3"
    force=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --access) access="''${2:?--access needs a value}"; shift 2 ;;
        --base-dir) base="''${2:?--base-dir needs a value}"; shift 2 ;;
        --force) force=1; shift ;;
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

    ${import ./cli-version.nix "t3-link-vm"}
    # `--` so a target that starts with a dash is a host, never an ssh option.
    code=$(ssh -o BatchMode=yes -- "$target" t3-pair 5m delegator) || {
      echo "t3-link-vm: could not mint a code on $target" >&2
      exit 1
    }
    # Exactly one line of plain characters: anything else (a login banner, two lines) is not a code.
    [[ "$code" =~ ^[A-Za-z0-9_-]{6,128}$ ]] || {
      echo "t3-link-vm: $target did not return a pairing code" >&2
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
