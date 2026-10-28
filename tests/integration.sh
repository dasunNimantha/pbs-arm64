#!/usr/bin/env bash
# End-to-end tests for a pbs-arm64 image: starts the server, then exercises the UI, the API
# and real backup/restore workflows with proxmox-backup-client.
#
#   tests/integration.sh <image> [static-client-deb]
#
# Needs docker and curl. Writes a summary to $GITHUB_STEP_SUMMARY when set.
set -uo pipefail

IMAGE=${1:?usage: integration.sh <image> [static-client-deb]}
STATIC_DEB=${2:-}
NET=pbs-test-net
SRV=pbs-test
PW='Int3gration-Test-Pa55'
WORK=$(mktemp -d)
PASS=0
FAIL=0
RESULTS=()

cleanup() {
  docker rm -f "$SRV" pbs-nosecret >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  # files under $WORK may be owned by the container's backup user
  docker run --rm -v "$WORK:/w" --entrypoint sh "$IMAGE" -c 'rm -rf /w/*' >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { PASS=$((PASS + 1)); RESULTS+=("✅ $1"); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); RESULTS+=("❌ $1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
# t "description" command... — passes if the command succeeds
t() { local d=$1; shift; if out=$("$@" 2>&1); then ok "$d"; else bad "$d"; printf '%s\n' "$out" | tail -20 | sed 's/^/       /'; fi; }
# tf "description" command... — passes if the command FAILS
tf() { local d=$1; shift; if out=$("$@" 2>&1); then bad "$d"; printf '%s\n' "$out" | tail -5 | sed 's/^/       /'; else ok "$d"; fi; }

sx() { docker exec "$SRV" "$@"; }                       # run on the server
mgr() { sx proxmox-backup-manager "$@"; }
api() { curl -ksf -H "Authorization: PBSAPIToken=$TOKEN_ID:$TOKEN_SECRET" "https://localhost:8007/api2/json$1"; }
# run proxmox-backup-client in a separate client container
client() {
  docker run --rm --network "$NET" --entrypoint proxmox-backup-client \
    -e PBS_REPOSITORY="$TOKEN_ID@$SRV:8007:${REPO_STORE:-store1}" -e PBS_PASSWORD="$TOKEN_SECRET" -e PBS_FINGERPRINT="$FP" \
    -v "$WORK/src:/src:ro" -v "$WORK/img:/img:ro" -v "$WORK/restore:/restore" -v "$WORK/keys:/keys" \
    "$IMAGE" "$@"
}
# snapshot helpers (run in this shell, so they can call client directly)
snaps() { client snapshot list --output-format json "$@"; }
latest_snap() { # backup-type backup-id [client args...]
  local type=$1 id=$2; shift 2
  snaps "$@" | python3 -c '
import json, sys, datetime
t, i = sys.argv[1], sys.argv[2]
s = sorted((x for x in json.load(sys.stdin) if x["backup-id"] == i), key=lambda x: x["backup-time"])
print(f"{t}/{i}/" + datetime.datetime.fromtimestamp(s[-1]["backup-time"], datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$type" "$id"
}
snap_count() { snaps | python3 -c 'import json,sys; print(sum(1 for x in json.load(sys.stdin) if x["backup-id"]==sys.argv[1]))' "$1"; }
same_tree() { [[ -d "$2" ]] && [[ -n "$(ls -A "$2")" ]] && diff <(tree_sig "$1") <(tree_sig "$2"); }
# owner of the process running binary $1. comm is truncated to 15 chars and /proc/<pid>/exe of a
# process that dropped privileges isn't readable without CAP_SYS_PTRACE, so match argv[0]
proc_user() { sx sh -c 'for p in /proc/[0-9]*; do a=$(tr "\0" "\n" < $p/cmdline 2>/dev/null | head -1); case "$a" in */"$1") stat -c %U $p; break;; esac; done' _ "$1"; }
# like grep -q, but reads all input: with pipefail, grep -q exiting early makes the writer fail (SIGPIPE)
has() { grep -e "$1" >/dev/null; }
login() { curl -ksf -d username=admin@pbs --data-urlencode "password=$1" https://localhost:8007/api2/json/access/ticket | has '"ticket"'; }
wait_up() { for _ in $(seq 90); do curl -ksf https://localhost:8007/ >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

start_server() {
  docker run -d --name "$SRV" --network "$NET" -p 8007:8007 --tmpfs /run \
    -v "$WORK/etc:/etc/proxmox-backup" -v "$WORK/lib:/var/lib/proxmox-backup" -v "$WORK/log:/var/log/proxmox-backup" \
    -v "$WORK/ds1:/datastore/store1" -v "$WORK/ds2:/datastore/store2" \
    -v "$WORK/secret:/run/secrets/pbs_admin_password:ro" "$IMAGE" >/dev/null
  wait_up || { docker logs "$SRV" | tail -30; return 1; }
}

mkdir -p "$WORK"/{etc,lib,log,ds1,ds2,src,img,restore,keys}
printf '%s\n' "$PW" > "$WORK/secret"
docker network create "$NET" >/dev/null

# ---------------------------------------------------------------- startup & security
log "Startup and security"
t "server starts and serves https on :8007" start_server
t "admin@pbs was created from the secret" bash -c "docker logs $SRV 2>&1 | grep -q 'created admin@pbs'"
t "running PBS version matches image label" bash -c \
  "test \"\$(docker exec $SRV dpkg-query -W -f='\${Version}' proxmox-backup-server | cut -d- -f1)\" = \"\$(docker inspect -f '{{ index .Config.Labels \"org.opencontainers.image.version\" }}' $IMAGE)\""
# ELF e_machine (bytes 18-19) 0xb7 = AArch64
t "server binaries are native aarch64" bash -c "docker exec $SRV od -An -j18 -N2 -tx1 /usr/sbin/proxmox-backup-manager | grep -q 'b7 00'"
t "login with correct password returns a ticket" login "$PW"
tf "login with a wrong password is rejected" login wrong
tf "no default credentials (admin@pbs / pbspbs)" login pbspbs
t "proxy runs as unprivileged 'backup' user" test "$(proc_user proxmox-backup-proxy)" = backup
t "API daemon runs as root (as upstream)" test "$(proc_user proxmox-backup-api)" = root
tf "internal API port 82 is not reachable from other containers" \
  docker run --rm --network "$NET" --entrypoint bash "$IMAGE" -c "timeout 5 bash -c 'echo > /dev/tcp/$SRV/82'"
t "a container without admin secret starts but has no users" bash -c "
  docker run -d --name pbs-nosecret --tmpfs /run $IMAGE >/dev/null && sleep 20 &&
  docker logs pbs-nosecret 2>&1 | grep -q 'no admin password' &&
  ! docker exec pbs-nosecret proxmox-backup-manager user list --output-format json | grep -q 'admin@pbs'"
docker rm -f pbs-nosecret >/dev/null 2>&1

# ---------------------------------------------------------------- web UI
log "Web UI"
t "index page references the PBS GUI bundle" bash -c "curl -ksf https://localhost:8007/ | grep -q 'proxmox-backup-gui.js'"
for asset in /js/proxmox-backup-gui.js /css/ext6-pbs.css /widgettoolkit/proxmoxlib.js /extjs/ext-all.js \
  /fontawesome/css/font-awesome.css /qrcodejs/qrcode.min.js /xtermjs/xterm.js; do
  t "UI asset $asset is served" curl -ksf -o /dev/null "https://localhost:8007$asset"
done
nag_removed() { curl -ksf https://localhost:8007/widgettoolkit/proxmoxlib.js | has 'pbs-arm64: subscription nag disabled'; }
t "subscription nag removed from the served UI toolkit" nag_removed
t "UI references every asset it loads (no 404s)" bash -c '
  # /pve2/images/logo-128.png: upstream index.hbs apple-touch-icon points at a PVE path (404 on official PBS too)
  curl -ksf https://localhost:8007/ | grep -oE "(src|href)=\"/[^\"]+\"" | sed -E "s/^(src|href)=\"//; s/\"$//; s/\?.*$//" | sort -u | grep -vx /pve2/images/logo-128.png |
  while read -r p; do curl -ksf -o /dev/null "https://localhost:8007$p" || { echo "missing: $p"; exit 1; }; done'

# ---------------------------------------------------------------- tokens & API
log "API"
t "create datastore store1" mgr datastore create store1 /datastore/store1
t "create datastore store2" mgr datastore create store2 /datastore/store2
t "datastore has chunk store layout" sx test -d /datastore/store1/.chunks/0000
# create the API token through the REST API with a ticket + CSRF token, as the web UI does
TICKET_JSON=$(curl -ksf -d username=admin@pbs --data-urlencode "password=$PW" https://localhost:8007/api2/json/access/ticket)
TICKET=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["ticket"])' <<<"$TICKET_JSON" 2>/dev/null)
CSRF=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["CSRFPreventionToken"])' <<<"$TICKET_JSON" 2>/dev/null)
TOKEN_JSON=$(curl -ksf -X POST -b "PBSAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF" \
  https://localhost:8007/api2/json/access/users/admin@pbs/token/ci)
TOKEN_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["tokenid"])' <<<"$TOKEN_JSON" 2>/dev/null)
TOKEN_SECRET=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["value"])' <<<"$TOKEN_JSON" 2>/dev/null)
t "API token created via REST (ticket + CSRF)" test -n "$TOKEN_SECRET" -a "$TOKEN_ID" = 'admin@pbs!ci'
tf "write request without CSRF token is rejected" curl -ksf -X POST -b "PBSAuthCookie=$TICKET" \
  https://localhost:8007/api2/json/access/users/admin@pbs/token/ci-nocsrf
t "grant token DatastoreAdmin on /datastore" mgr acl update /datastore DatastoreAdmin --auth-id "$TOKEN_ID"
t "grant token Audit on / (node status)" mgr acl update / Audit --auth-id "$TOKEN_ID"
FP=$(mgr cert info 2>/dev/null | sed -n 's/^Fingerprint (sha256): //p')
t "server certificate fingerprint available" test -n "$FP"
api_has() { api "$1" | has "$2"; }
t "API: version" api_has /version release
t "API: node status" api_has /nodes/localhost/status cpuinfo
both_stores() { local l; l=$(api /admin/datastore) && grep -q store1 <<<"$l" && grep -q store2 <<<"$l"; }
t "API: datastore list contains store1 and store2" both_stores
t "API: datastore usage" api_has /status/datastore-usage store1
tf "API rejects a bad token" curl -ksf -H "Authorization: PBSAPIToken=$TOKEN_ID:00000000-0000-0000-0000-000000000000" https://localhost:8007/api2/json/admin/datastore

# ---------------------------------------------------------------- test data
mkdir -p "$WORK/src/dir/sub" "$WORK/src/empty"
head -c 20M /dev/urandom > "$WORK/src/random.bin"
seq 1 200000 > "$WORK/src/dir/numbers.txt"
printf 'hello pbs\n' > "$WORK/src/dir/sub/hello.txt"
chmod 640 "$WORK/src/dir/sub/hello.txt"
ln -s dir/sub/hello.txt "$WORK/src/link"
head -c 64M /dev/urandom > "$WORK/img/disk.raw"

# ---------------------------------------------------------------- backup & restore
log "Backup and restore"
t "file-level backup (pxar)" client backup data.pxar:/src --backup-id ci-host
t "block-level backup (img)" client backup disk.img:/img/disk.raw --backup-id ci-disk --backup-type vm
SNAP=$(latest_snap host ci-host 2>/dev/null)
t "snapshot listed" test -n "$SNAP"
t "restore pxar archive" client restore "$SNAP" data.pxar /restore/data
t "restored files identical (content, modes, symlinks, empty dir)" same_tree "$WORK/src" "$WORK/restore/data"
SNAP_IMG=$(latest_snap vm ci-disk 2>/dev/null)
t "restore img archive" client restore "$SNAP_IMG" disk.img /restore/disk.raw
t "restored disk image identical" cmp "$WORK/img/disk.raw" "$WORK/restore/disk.raw"
# catalog dump prints the listing on stderr
catalog_has() { client catalog dump "$1" 2>&1 | has "$2"; }
t "catalog lists backed-up files" catalog_has "$SNAP" hello.txt

log "Deduplication"
chunks() { sx sh -c 'find /datastore/store1/.chunks -type f | wc -l'; }
BEFORE=$(chunks)
t "first backups created chunks ($BEFORE)" test "$BEFORE" -gt 10
sleep 1
t "unchanged second backup succeeds" client backup data.pxar:/src --backup-id ci-host
AFTER=$(chunks)
t "unchanged second backup added no new chunks ($BEFORE -> $AFTER)" test "$BEFORE" -eq "$AFTER"

# ---------------------------------------------------------------- encryption
log "Client-side encryption"
t "create encryption key" client key create /keys/enc.key --kdf none
t "encrypted backup" client backup data.pxar:/src --backup-id ci-enc --keyfile /keys/enc.key
SNAP_ENC=$(latest_snap host ci-enc 2>/dev/null)
enc_marked() { snaps | python3 -c 'import json,sys; s=[x for x in json.load(sys.stdin) if x["backup-id"]=="ci-enc"]; assert all(f.get("crypt-mode")=="encrypt" for x in s for f in x["files"] if f["filename"].endswith(".didx")), s' ; }
t "snapshot archives are marked encrypted" enc_marked
t "restore encrypted backup with key" client restore "$SNAP_ENC" data.pxar /restore/enc --keyfile /keys/enc.key
t "decrypted restore identical" same_tree "$WORK/src" "$WORK/restore/enc"
tf "restore without key fails" client restore "$SNAP_ENC" data.pxar /restore/nokey
t "create a second, different key" client key create /keys/other.key --kdf none
tf "restore with the wrong key fails" client restore "$SNAP_ENC" data.pxar /restore/wrongkey --keyfile /keys/other.key

# ---------------------------------------------------------------- namespaces
log "Namespaces"
t "create namespace ci-ns" client namespace create ci-ns
t "backup into namespace" client backup data.pxar:/src --backup-id ci-ns-host --ns ci-ns
in_ns() { snaps ${1:+--ns "$1"} | has ci-ns-host; }
t "namespace backup visible in namespace" in_ns ci-ns
tf "namespace backup not in root namespace" in_ns ""

# ---------------------------------------------------------------- maintenance
log "Verify, prune, garbage collection"
verify_ok() { local o; o=$(mgr verify store1 2>&1) && ! grep -qiE 'failed|corrupt' <<<"$o"; }
t "verify datastore: all snapshots OK" verify_ok
t "prune keeps only the last ci-host snapshot" client prune host/ci-host --keep-last 1
t "only 1 ci-host snapshot left after prune" test "$(snap_count ci-host)" = 1
t "garbage collection runs" mgr garbage-collection start store1
t "garbage collection status reported" mgr garbage-collection status store1
tasks_ok() { mgr task list --all --output-format json | python3 -c 'import json,sys; t=json.load(sys.stdin); bad=[x for x in t if x.get("status") not in (None,"OK")]; assert t and not bad, bad'; }
t "task list: all tasks OK" tasks_ok

# ---------------------------------------------------------------- sync (pull)
log "Sync job (pull from itself over TLS)"
t "create remote pointing at itself" mgr remote create self --host localhost --auth-id "$TOKEN_ID" --password "$TOKEN_SECRET" --fingerprint "$FP"
t "pull store1 -> store2" mgr pull self store1 store2
synced_has() { REPO_STORE=store2 snaps | has ci-disk; }
t "pulled snapshots present in store2" synced_has
restore_synced() { REPO_STORE=store2 client restore "$SNAP_IMG" disk.img /restore/synced.raw && cmp "$WORK/img/disk.raw" "$WORK/restore/synced.raw"; }
t "restore from synced copy identical" restore_synced

# ---------------------------------------------------------------- static client
if [[ -n "$STATIC_DEB" ]]; then
  log "Static client"
  mkdir -p "$WORK/static"
  t "extract static client package" dpkg-deb -x "$STATIC_DEB" "$WORK/static"
  t "static client is statically linked" bash -c "file '$WORK/static/usr/bin/proxmox-backup-client' | grep -q 'statically linked'"
  t "static client runs on the host" "$WORK/static/usr/bin/proxmox-backup-client" version
  t "static client backup to the server" env PBS_REPOSITORY="$TOKEN_ID@localhost:8007:store1" PBS_PASSWORD="$TOKEN_SECRET" PBS_FINGERPRINT="$FP" \
    "$WORK/static/usr/bin/proxmox-backup-client" backup static.pxar:"$WORK/src" --backup-id ci-static
fi

# ---------------------------------------------------------------- persistence
log "Persistence across restart"
restart_server() { docker restart "$SRV" >/dev/null && wait_up; }
t "container restarts cleanly" restart_server
t "admin login still works" login "$PW"
t "admin not re-created on restart" bash -c "test \$(docker logs $SRV 2>&1 | grep -c 'created admin@pbs') -eq 1"
t "token and snapshots survive restart" test "$(snap_count ci-disk)" -ge 1
t "restore after restart" client restore "$SNAP_IMG" disk.img /restore/after-restart.raw
t "certificate fingerprint unchanged" test "$(mgr cert info 2>/dev/null | sed -n 's/^Fingerprint (sha256): //p')" = "$FP"

# ---------------------------------------------------------------- other binaries
log "Other components"
t "proxmox-termproxy installed (native)" bash -c "docker exec $SRV od -An -j18 -N2 -tx1 /usr/libexec/proxmox/proxmox-termproxy | grep -q 'b7 00'"
t "mini-journalreader is installed" sx test -x /usr/bin/mini-journalreader
t "benchmark (sha256/aes/zstd)" bash -c "docker exec $SRV proxmox-backup-client benchmark --output-format json | tee '$WORK/bench.json' | grep -q aes256_gcm"
tf "server logs contain no panics" bash -c "docker logs $SRV 2>&1 | grep -iE 'panicked at|segfault|core dumped'"

# ---------------------------------------------------------------- summary
log "Result: $PASS passed, $FAIL failed"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Integration tests: $PASS passed, $FAIL failed"
    echo
    echo "Image: \`$IMAGE\`"
    echo
    printf -- '- %s\n' "${RESULTS[@]}"
    if [[ -s "$WORK/bench.json" ]]; then
      echo
      echo "<details><summary>Benchmark</summary>"
      echo
      echo '```json'
      cat "$WORK/bench.json"
      echo '```'
      echo "</details>"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
((FAIL == 0))
