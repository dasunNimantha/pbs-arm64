#!/usr/bin/env bash
# Run the two PBS daemons without systemd:
#   proxmox-backup-api   (root, local API on 127.0.0.1:82)
#   proxmox-backup-proxy (user backup, public HTTPS API + UI on :8007)
# If either exits, the container exits so the restart policy can bring it back cleanly.
#
# First start: creates admin@pbs with the password read from $PBS_ADMIN_PASSWORD_FILE.
# There is no default password.
set -euo pipefail

LIB=$(echo /usr/lib/*/proxmox-backup)
[[ -x "$LIB/proxmox-backup-api" ]] || { echo "proxmox-backup not installed?" >&2; exit 1; }

for d in /etc/proxmox-backup /var/lib/proxmox-backup /var/log/proxmox-backup; do
  mkdir -p "$d"
  chown backup:backup "$d"
  chmod 700 "$d"
  mountpoint -q "$d" || echo "WARNING: $d is not a volume; its contents are lost when the container is removed" >&2
done
mountpoint -q /run || echo "WARNING: /run should be a tmpfs (docker run --tmpfs /run)" >&2
mkdir -p /run/proxmox-backup && chown backup:backup /run/proxmox-backup

# stale locks from an unclean stop
rm -f /etc/proxmox-backup/.*.lck

"$LIB/proxmox-backup-api" &
API=$!
for _ in $(seq 60); do
  [[ -e /etc/proxmox-backup/proxy.pem ]] && [[ -e /etc/proxmox-backup/csrf.key ]] && break
  kill -0 "$API" 2>/dev/null || { echo "proxmox-backup-api exited during startup" >&2; exit 1; }
  sleep 1
done

if [[ ! -e /etc/proxmox-backup/.admin-initialized ]]; then
  PW_FILE=${PBS_ADMIN_PASSWORD_FILE:-/run/secrets/pbs_admin_password}
  if [[ -s "$PW_FILE" ]]; then
    proxmox-backup-manager user create admin@pbs --password "$(head -n1 "$PW_FILE")" --comment "created by container entrypoint"
    proxmox-backup-manager acl update / Admin --auth-id admin@pbs
    touch /etc/proxmox-backup/.admin-initialized
    echo "created admin@pbs"
  else
    echo "WARNING: no admin password at $PW_FILE; no user can log in yet." >&2
    echo "         Create one with: docker exec <container> proxmox-backup-manager user create ..." >&2
  fi
fi

su -s /bin/sh backup -c "exec $LIB/proxmox-backup-proxy" &
PROXY=$!
echo "Proxmox Backup Server $(dpkg-query -W -f='${Version}' proxmox-backup-server) running on :8007"

trap 'kill -TERM "$API" "$PROXY" 2>/dev/null' TERM INT
wait -n "$API" "$PROXY"
status=$?
kill -TERM "$API" "$PROXY" 2>/dev/null || true
wait || true
exit "$status"
