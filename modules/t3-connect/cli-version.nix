# modules/t3-connect/cli-version.nix
# Shell fragment shared by t3-link-vm and t3-unlink-vm: refuse a `t3` CLI whose version differs from the
# delegator's. Reads $t3, $base and $force; `name` prefixes the messages.
name: ''
  cli=$("$t3" --version | sed 's/^t3 v//')
  runtime="$base/userdata/server-runtime.json"
  server=""
  [ -f "$runtime" ] && server=$(jq -r '.serverVersion // empty' "$runtime")
  if [ -n "$server" ]; then
    if [ "$server" != "$cli" ]; then
      echo "${name}: the t3 CLI is $cli but the delegator is $server; use a CLI built for $server" >&2
      exit 1
    fi
  elif [ "$force" = 1 ]; then
    echo "${name}: cannot compare versions (no serverVersion in $runtime); going on because of --force" >&2
  else
    echo "${name}: cannot compare versions: no serverVersion in $runtime (is the delegator running?); start it, or pass --force" >&2
    exit 1
  fi
''
