# Body of t3-sandy (modules/t3-connect/sandy.nix puts `t3_default` before it).
# One command for the whole life of a sandy-run T3 guest, from the Mac that runs the T3 app:
#   start the job on the sandy host -> find the guest and its pairing code -> tunnel its port ->
#   link it in the app -> hold until the job ends or this command is signalled -> stop the job -> unlink.
# Exits non-zero when the unlink fails. Every run first unlinks entries left by a run that died.
# The sandy-side scripts (start.sh, guest.sh) are not part of this package: --start-script names them.

usage() {
  cat >&2 <<'USAGE'
usage: t3-sandy [options]
  --host H            ssh name of the sandy host (default ws01)
  --sandy-dir D       sandy checkout on that host (default $HOME/sandy-b7, expanded there)
  --base-dir DIR      the T3 app's data dir on this machine (default ~/.t3)
  --access MODE       link access mode (default full-access)
  --start-script P    directory with start.sh and guest.sh, or the path of start.sh (required to start a job)
  --job-timeout SEC   sandy job timeout (default 604800)
  --ready-timeout SEC wait for the guest and its code (default 300)
  --no-preflight      skip the check of the sandy host's trust roots
  --force             go on when the CLI and app versions cannot be compared
  --reap-only         unlink entries of ended jobs and exit
  --no-reap           skip that cleanup at start
USAGE
  exit 2
}

host=ws01
# shellcheck disable=SC2016 # expanded on the sandy host
sandy_dir='$HOME/sandy-b7'
base="$HOME/.t3"
access=full-access
start_script=
job_timeout=604800
preflight=1
ready_timeout=300
force=0
reap_only=0
reap=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host) host="${2:?--host needs a value}"; shift 2 ;;
    --sandy-dir) sandy_dir="${2:?--sandy-dir needs a value}"; shift 2 ;;
    --base-dir) base="${2:?--base-dir needs a value}"; shift 2 ;;
    --access) access="${2:?--access needs a value}"; shift 2 ;;
    --start-script) start_script="${2:?--start-script needs a value}"; shift 2 ;;
    --no-preflight) preflight=0; shift ;;
    --job-timeout) job_timeout="${2:?--job-timeout needs a value}"; shift 2 ;;
    --ready-timeout) ready_timeout="${2:?--ready-timeout needs a value}"; shift 2 ;;
    --force) force=1; shift ;;
    --reap-only) reap_only=1; shift ;;
    --no-reap) reap=0; shift ;;
    -h | --help) usage ;;
    *) echo "t3-sandy: unknown argument $1" >&2; usage ;;
  esac
done
case "$job_timeout$ready_timeout" in *[!0-9]* | "") echo "t3-sandy: timeouts are whole seconds" >&2; exit 2 ;; esac
if [ "$reap_only" = 0 ]; then
  [ -n "$start_script" ] || { echo "t3-sandy: --start-script is required" >&2; usage; }
  [ -d "$start_script" ] || start_script="$(dirname -- "$start_script")"
  for f in start.sh guest.sh; do
    [ -f "$start_script/$f" ] || { echo "t3-sandy: $start_script/$f not found" >&2; exit 2; }
  done
fi

t3="${T3_BIN:-$t3_default}"
export T3_BIN="$t3"
state="${XDG_STATE_HOME:-$HOME/.local/state}/t3-sandy"
mkdir -p "$state"
sandy_bin="$sandy_dir/target/release/sandy"

log() { echo "t3-sandy: $*" >&2; }
# Remote commands run on the sandy host; $sandy_dir and ~ expand there.
rs() { ssh -o BatchMode=yes -- "$host" "$@"; }

# Same version rule as t3-link-vm: the CLI writes the app's database.
CLI_VERSION_CHECK

# An entry is left over when the app lists it as unreachable and its sandy job has a result.
reap_entries() {
  local f envid job status ended
  for f in "$state"/*; do
    [ -f "$f" ] || continue
    envid="${f##*/}"
    job="$(cat "$f")"
    status=$("$t3" environment list --json --base-dir "$base" | jq -r --arg i "$envid" '.[] | select(.environmentId == $i) | .status')
    if [ -z "$status" ]; then rm -f "$f"; continue; fi
    [ "$status" = unreachable ] || continue
    ended=$(rs "jq -r 'if .result then \"yes\" else \"no\" end' ~/.sandy/jobs/$job.json" 2>/dev/null) || {
      log "cannot read job $job on $host; leaving $envid linked"
      continue
    }
    [ "$ended" = yes ] || continue
    if t3-unlink-vm --base-dir "$base" --force -- "$envid"; then rm -f "$f"; else log "could not unlink the leftover $envid"; reap_failed=1; fi
  done
}
reap_failed=0
if [ "$reap" = 1 ] || [ "$reap_only" = 1 ]; then reap_entries; fi
if [ "$reap_only" = 1 ]; then exit "$reap_failed"; fi

nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
unit="sandbox-$(printf '%s' "$nonce" | cut -c1-6)"
workdir=".cache/t3-sandy/$nonce"
job=""
envid=""
tunnel_pid=""
wait_pid=""
unlink_failed=0

stop_job() {
  [ -n "$job" ] || return 0
  local ended
  ended=$(rs "jq -r 'if .result then \"yes\" else \"no\" end' ~/.sandy/jobs/$job.json" 2>/dev/null) || ended=unknown
  [ "$ended" = yes ] && return 0
  log "stopping job $job"
  rs "$sandy_bin kill $job" >/dev/null 2>&1 || true
  ended=$(rs "jq -r 'if .result then \"yes\" else \"no\" end' ~/.sandy/jobs/$job.json" 2>/dev/null) || ended=unknown
  if [ "$ended" != yes ]; then
    log "sandy kill did not end the job; stopping the unit (sudo prompt)"
    ssh -t -- "$host" "sudo systemctl stop $unit" || log "could not stop $unit: run 'sudo systemctl stop $unit' on $host"
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [ -z "$wait_pid" ] || kill "$wait_pid" 2>/dev/null || true
  stop_job
  if [ -n "$envid" ]; then
    if t3-unlink-vm --base-dir "$base" --force -- "$envid"; then
      rm -f "$state/$envid"
    else
      log "unlink of $envid failed; the next run unlinks it once the job has ended"
      unlink_failed=1
    fi
  fi
  [ -z "$tunnel_pid" ] || kill "$tunnel_pid" 2>/dev/null || true
  rs "rm -rf $workdir" >/dev/null 2>&1 || true
  { [ "$unlink_failed" = 0 ] && [ "$reap_failed" = 0 ]; } || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

job_ended() {
  [ "$(rs "jq -r 'if .result then \"yes\" else \"no\" end' ~/.sandy/jobs/$job.json" 2>/dev/null)" = yes ]
}

# The trailing `true` keeps an empty job directory from failing the listing; a dead connection still does.
job_files() { rs 'ls ~/.sandy/jobs/ 2>/dev/null; true' | { grep '\.json$' || true; } | sort; }
before=$(job_files) || { log "cannot reach $host"; exit 1; }

# sandy runs as root in the unit and refuses trust roots that are not root's. Only the directory can be
# checked from here when it is root-owned and 700; files inside it are checked when they are readable.
# shellcheck disable=SC2016 # runs on the sandy host
trust_check='d=$HOME/.config/sandy/trust-roots; [ -d "$d" ] || { echo missing; exit 0; }; bad=$(find "$d" \( ! -user root -o -perm /077 \) 2>/dev/null | head -n1); if [ -n "$bad" ]; then echo "bad $bad"; else echo ok; fi'
if [ "$preflight" = 1 ]; then
  fix='sudo chown -R root:root ~/.config/sandy/trust-roots && sudo chmod -R go-rwx ~/.config/sandy/trust-roots'
  checked=$(rs "$trust_check" 2>/dev/null) || { log "cannot reach $host"; exit 1; }
  case "$checked" in
    ok) ;;
    missing) log "no ~/.config/sandy/trust-roots on $host: sandy has no trust root to mint credentials with"; exit 1 ;;
    *) log "${checked#bad } on $host is not owned by root or is open to others; sandy refuses it"
       log "fix it with: ssh -t $host '$fix'"
       exit 1 ;;
  esac
fi

# Start the job: upload the guest files and run start.sh with a terminal, so the sudo prompt reaches you.
for f in guest.sh start.sh; do
  rs "mkdir -p $workdir && cat > $workdir/$f" < "$start_script/$f" || { log "could not upload $f"; exit 1; }
done
log "starting $unit on $host (sudo password prompt)"
ssh -t -- "$host" "UNIT=$unit NONCE=$nonce JOB_TIMEOUT=$job_timeout SANDY_DIR=$sandy_dir bash $workdir/start.sh" \
  || { log "the start step failed"; exit 1; }

deadline=$((SECONDS + 60))
while [ -z "$job" ] && [ "$SECONDS" -lt "$deadline" ]; do
  new=$(comm -13 <(printf '%s\n' "$before") <(job_files) | head -n1)
  [ -z "$new" ] || job="${new%.json}"
  [ -n "$job" ] || sleep 2
done
[ -n "$job" ] || { log "no new sandy job record after 60 s"; exit 1; }
log "job $job"

# The guest publishes its code at http://<guest>:3774/<nonce>; the first neighbour that serves it is the guest.
# shellcheck disable=SC2016 # runs on the sandy host
probe='for ip in $(ip -4 neigh show dev sbr0 | cut -d" " -f1); do c=$(curl -fsS --max-time 2 "http://$ip:3774/'"$nonce"'") && { echo "$ip $c"; break; }; done'
guest_ip=""
code=""
deadline=$((SECONDS + ready_timeout))
while [ -z "$code" ] && [ "$SECONDS" -lt "$deadline" ]; do
  job_ended && { log "the job ended before the guest was ready"; exit 1; }
  got=$(rs "$probe" 2>/dev/null || true)
  if [[ "$got" =~ ^([0-9.]+)\ ([A-Za-z0-9_-]{6,128})$ ]]; then guest_ip="${BASH_REMATCH[1]}"; code="${BASH_REMATCH[2]}"; fi
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
ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -L "127.0.0.1:$port:$guest_ip:3773" -- "$host" &
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
printf '%s\n' "$job" > "$state/$envid"
log "linked $envid at $url; holding until job $job ends (Ctrl-C stops it and unlinks)"

# A dropped ssh ends `sandy wait` early: ask again until the record has a result.
until job_ended; do
  rs "$sandy_bin wait $job -o json" > /dev/null 2>&1 &
  wait_pid=$!
  wait "$wait_pid" || true
  wait_pid=""
  job_ended || sleep 5
done
log "job $job ended"
