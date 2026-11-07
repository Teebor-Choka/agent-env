# Body of t3-run-vm (modules/t3-connect/run-vm.nix puts `t3_default` before it).
# One command for the whole life of a T3 guest that has no mesh and no sshd of its own, from the machine that
# runs the T3 app: start the guest's unit on its host -> find the guest and its pairing code -> tunnel its
# port -> link it in the app -> hold until the unit stops or this command is signalled -> stop the unit -> unlink.
# The entry is unlinked on every way the guest ends: an exit or signal trap unlinks it locally first; a run that
# cannot trap (kill -9, power loss, reboot) is cleaned up by --reap-only, which every run and a launchd agent call.
# Exits non-zero when the unlink fails or the guest's unit cannot be stopped.
# The host-side start script is not part of this package: --start-script names it (see docs/t3-connect-setup.md).

usage() {
  cat >&2 <<'USAGE'
usage: t3-run-vm --host H (--guest ADDR | --bridge DEV) --start-script P [options]
       t3-run-vm --host H --reap-only
  --host H            ssh name of the machine that runs the guest
  --guest ADDR        the guest's address as the host sees it
  --bridge DEV        or: find the guest among the host's neighbours on this bridge
  --start-script P    directory with start.sh (and any files it needs), or the path of start.sh
  --start-env K=V     environment for start.sh, repeatable (UNIT, NONCE, JOB_TIMEOUT are always set)
  --base-dir DIR      the T3 app's data dir on this machine (default ~/.t3)
  --access MODE       link access mode (default full-access)
  --job-timeout SEC   passed to start.sh as JOB_TIMEOUT (default 604800)
  --ready-timeout SEC wait for the guest and its code (default 300)
  --code-port N       guest port that serves the pairing code at /<nonce> (default 3774)
  --guest-port N      guest port of the T3 server (default 3773)
  --force             go on when the CLI and app versions cannot be compared
  --reap-only         unlink entries of ended guests and exit
  --no-reap           skip that cleanup at start
USAGE
  exit 2
}

host=
guest=
bridge=
base="$HOME/.t3"
access=full-access
start_script=
start_env=()
job_timeout=604800
ready_timeout=300
code_port=3774
guest_port=3773
force=0
reap_only=0
reap=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host="${2:?--host needs a value}"; shift 2 ;;
    --guest) guest="${2:?--guest needs a value}"; shift 2 ;;
    --bridge) bridge="${2:?--bridge needs a value}"; shift 2 ;;
    --start-script) start_script="${2:?--start-script needs a value}"; shift 2 ;;
    --start-env) start_env+=("${2:?--start-env needs K=V}"); shift 2 ;;
    --base-dir) base="${2:?--base-dir needs a value}"; shift 2 ;;
    --access) access="${2:?--access needs a value}"; shift 2 ;;
    --job-timeout) job_timeout="${2:?--job-timeout needs a value}"; shift 2 ;;
    --ready-timeout) ready_timeout="${2:?--ready-timeout needs a value}"; shift 2 ;;
    --code-port) code_port="${2:?--code-port needs a value}"; shift 2 ;;
    --guest-port) guest_port="${2:?--guest-port needs a value}"; shift 2 ;;
    --force) force=1; shift ;;
    --reap-only) reap_only=1; shift ;;
    --no-reap) reap=0; shift ;;
    -h | --help) usage ;;
    *) echo "t3-run-vm: unknown argument $1" >&2; usage ;;
  esac
done
die() { echo "t3-run-vm: $*" >&2; exit 2; }
[ -n "$host" ] || die "--host is required"
case "$job_timeout$ready_timeout$code_port$guest_port" in *[!0-9]* | "") die "timeouts and ports are whole numbers" ;; esac
# These go into a command that runs on the host.
[[ "$host$guest$bridge" =~ ^[A-Za-z0-9_.:@-]*$ ]] || die "--host, --guest and --bridge take plain names and addresses"
for kv in "${start_env[@]}"; do
  [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:@%+=,$~-]*$ ]] || die "--start-env $kv: use K=V without spaces or quotes"
done
if [ "$reap_only" = 0 ]; then
  [ -n "$start_script" ] || die "--start-script is required"
  [ -n "$guest$bridge" ] || die "give --guest or --bridge"
  [ -d "$start_script" ] || start_script="$(dirname -- "$start_script")"
  [ -f "$start_script/start.sh" ] || die "$start_script/start.sh not found"
fi

t3="${T3_BIN:-$t3_default}"
export T3_BIN="$t3"
state="${XDG_STATE_HOME:-$HOME/.local/state}/t3-run-vm"
mkdir -p "$state"

log() { echo "t3-run-vm: $*" >&2; }
# Remote commands run on the guest's host. Every one is bounded, so a dead host cannot hold up the exit trap or
# the reaper.
rs() { timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -- "$host" "$@"; }

# Same version rule as t3-link-vm: the CLI writes the app's database.
CLI_VERSION_CHECK

# The unit's own state decides whether the guest runs; a job or run record the start script keeps is not read.
unit_state() { rs "systemctl is-active ${1:-$unit} || true" 2>/dev/null || echo unknown; }
stopped_state() { case "$1" in inactive | failed) return 0 ;; *) return 1 ;; esac; }

# Idempotent: an entry that is already gone counts as unlinked.
unlink_env() {
  local listed
  if listed=$("$t3" environment list --json --base-dir "$base" 2>/dev/null) &&
    ! printf '%s' "$listed" | jq -e --arg i "$1" '.[] | select(.environmentId == $i)' >/dev/null; then
    return 0
  fi
  t3-unlink-vm --base-dir "$base" --force -- "$1"
}

# A state file records an entry this tool made: key=value lines unit, linkedAt and, set by the reaper,
# unreachableSince.
st_get() { sed -n "s/^$2=//p" "$1" | head -n1; }
st_del() { { grep -v "^$2=" "$1" || true; } > "$1.tmp" && mv "$1.tmp" "$1"; }
st_set() { st_del "$1" "$2" && printf '%s=%s\n' "$2" "$3" >> "$1"; }

# An entry is left over when the app lists it as unreachable and either the host reports the guest's unit
# inactive, or the host stays unreachable over two checks `recheck` seconds apart (so a mesh blip does not
# drop a live link). A guest that still runs keeps its entry; the reaper never stops one.
recheck="${T3_RUN_VM_RECHECK:-120}"
reap_entries() {
  local f envid unit status since up=""
  for f in "$state"/*; do
    [ -f "$f" ] || continue
    envid="${f##*/}"
    unit=$(st_get "$f" unit)
    status=$("$t3" environment list --json --base-dir "$base" | jq -r --arg i "$envid" '.[] | select(.environmentId == $i) | .status')
    if [ -z "$status" ]; then rm -f "$f"; continue; fi
    if [ "$status" != unreachable ]; then st_del "$f" unreachableSince; continue; fi
    [ -n "$up" ] || { if rs true >/dev/null 2>&1; then up=yes; else up=no; fi; }
    if [ "$up" = yes ]; then
      st_del "$f" unreachableSince
      if [ -z "$unit" ]; then log "no unit recorded for $envid; leaving it linked"; continue; fi
      stopped_state "$(unit_state "$unit")" || continue
    else
      since=$(st_get "$f" unreachableSince)
      if [ -z "$since" ]; then
        st_set "$f" unreachableSince "$(date +%s)"
        log "$host and $envid are both unreachable: checking again in ${recheck} s"
        continue
      fi
      [ $(($(date +%s) - since)) -ge "$recheck" ] || continue
    fi
    if unlink_env "$envid"; then rm -f "$f"; else log "could not unlink the leftover $envid"; reap_failed=1; fi
  done
}
reap_failed=0
if [ "$reap" = 1 ] || [ "$reap_only" = 1 ]; then reap_entries; fi
if [ "$reap_only" = 1 ]; then exit "$reap_failed"; fi

nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
unit="t3vm-$(printf '%s' "$nonce" | cut -c1-6)"
workdir=".cache/t3-run-vm/$nonce"
envid=""
tunnel_pid=""
unlink_failed=0
leaked=0
started=0

stop_job() {
  [ "$started" = 1 ] || return 0
  stopped_state "$(unit_state)" && return 0
  log "stopping $unit (sudo prompt)"
  ssh -t -o ConnectTimeout=10 -- "$host" "sudo systemctl stop $unit" || log "could not stop $unit: run 'sudo systemctl stop $unit' on $host"
  stopped_state "$(unit_state)" || { log "$unit may still run on $host"; leaked=1; }
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  # Unlink first: it is local to this machine's database and must not wait for the host.
  if [ -n "$envid" ]; then
    if unlink_env "$envid"; then
      rm -f "$state/$envid"
    else
      log "unlink of $envid failed; the next run unlinks it once the unit has stopped"
      unlink_failed=1
    fi
  fi
  [ -z "$tunnel_pid" ] || kill "$tunnel_pid" 2>/dev/null || true
  stop_job
  rs "rm -rf $workdir" >/dev/null 2>&1 || true
  { [ "$unlink_failed" = 0 ] && [ "$reap_failed" = 0 ] && [ "$leaked" = 0 ]; } || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The guest is over when its unit is no longer running.
guest_gone() { stopped_state "$(unit_state)"; }

# Start the guest: upload the start script's files and run start.sh with a terminal, so a sudo prompt reaches you.
for f in "$start_script"/*; do
  [ -f "$f" ] || continue
  rs "mkdir -p $workdir && cat > $workdir/${f##*/}" < "$f" || { log "could not upload ${f##*/}"; exit 1; }
done
log "starting $unit on $host"
started=1
ssh -t -o ConnectTimeout=10 -- "$host" "UNIT=$unit NONCE=$nonce JOB_TIMEOUT=$job_timeout ${start_env[*]:-} bash $workdir/start.sh" \
  || { log "the start step failed"; exit 1; }

# The guest publishes its code at http://<guest>:<code-port>/<nonce>; the first address that serves it is the guest.
if [ -n "$guest" ]; then addrs="$guest"; else addrs="\$(ip -4 neigh show dev $bridge | cut -d' ' -f1)"; fi
probe="for ip in $addrs; do c=\$(curl -fsS --max-time 2 \"http://\$ip:$code_port/$nonce\") && { echo \"\$ip \$c\"; break; }; done"
guest_ip=""
code=""
deadline=$((SECONDS + ready_timeout))
while [ -z "$code" ] && [ "$SECONDS" -lt "$deadline" ]; do
  guest_gone && { log "the guest stopped before it was ready"; exit 1; }
  got=$(rs "$probe" 2>/dev/null || true)
  if [[ "$got" =~ ^([0-9A-Fa-f.:]+)\ ([A-Za-z0-9_-]{6,128})$ ]]; then guest_ip="${BASH_REMATCH[1]}"; code="${BASH_REMATCH[2]}"; fi
  [ -n "$code" ] || sleep 3
done
[ -n "$code" ] || { log "no pairing code from the guest in ${ready_timeout} s"; exit 1; }
log "guest at $guest_ip"

port=""
for _ in $(seq 20); do
  p=$((20000 + RANDOM % 20000))
  # shellcheck disable=SC2261
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then port=$p; break; fi
done
[ -n "$port" ] || { log "no free local port"; exit 1; }
ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -L "127.0.0.1:$port:$guest_ip:$guest_port" -- "$host" &
tunnel_pid=$!
url="http://localhost:$port"
deadline=$((SECONDS + 30))
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url/" 2>/dev/null || true; }
# t3 answers 503 while it starts and below 500 once it serves.
until c=$(http_code); [ "${c:-0}" -ge 100 ] && [ "${c:-0}" -lt 500 ]; do
  [ "$SECONDS" -lt "$deadline" ] || { log "the guest does not answer through the tunnel at $url"; exit 1; }
  sleep 1
done

out=$("$t3" environment link "$url" --pairing-code "$code" --access "$access" --base-dir "$base" 2>&1) || {
  printf '%s\n' "${out//"$code"/<code>}" >&2
  log "the link failed"
  exit 1
}
printf '%s\n' "${out//"$code"/<code>}"
envid=$("$t3" environment list --json --base-dir "$base" | jq -r --arg u "$url" '.[] | select(.urls | index($u)) | .environmentId' | head -n1)
[ -n "$envid" ] || { log "linked, but the entry for $url is not listed"; exit 1; }
{
  printf 'unit=%s\n' "$unit"
  date -u +linkedAt=%Y-%m-%dT%H:%M:%SZ
} > "$state/$envid"
log "linked $envid at $url; holding until $unit stops (Ctrl-C stops it and unlinks)"

# The sleep runs in the background so a signal ends it at once.
until guest_gone; do
  kill -0 "$tunnel_pid" 2>/dev/null || { log "the tunnel to the guest dropped"; exit 1; }
  sleep "${T3_RUN_VM_POLL:-10}" &
  wait $!
done
log "$unit stopped"
