#!/usr/bin/env bash
set -euo pipefail

export ETCDCTL_API=3

ENDPOINTS="${ETCD_ENDPOINTS:-192.168.192.129:2379,192.168.192.130:2379,192.168.192.131:2379}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/etcd-backups}"
CLUSTER_NAME="${CLUSTER_NAME:-cluster_1}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
LOCAL_FALLBACK_DIR="${LOCAL_FALLBACK_DIR:-/var/backups/etcd/local-spool}"

TIMESTAMP="$(date +%F_%H%M%S)"
DEST_DIR="${NFS_MOUNT}/${CLUSTER_NAME}"
SNAPSHOT_FILE="${DEST_DIR}/etcd-snapshot-${TIMESTAMP}.db"

if [[ -n "${ETCDCTL_CACERT:-}" && -n "${ETCDCTL_CERT:-}" && -n "${ETCDCTL_KEY:-}" ]]; then
  TLS_ARGS=(--cacert "${ETCDCTL_CACERT}" --cert "${ETCDCTL_CERT}" --key "${ETCDCTL_KEY}")
else
  TLS_ARGS=()
fi

ensure_dir() {
  local path="$1"
  sudo mkdir -p "$path"
}

write_snapshot() {
  local target_file="$1"
  etcdctl --endpoints="$ENDPOINTS" "${TLS_ARGS[@]}" snapshot save "$target_file"
  etcdctl snapshot status "$target_file" -w table
  sha256sum "$target_file" > "${target_file}.sha256"
}

purge_old() {
  local target_root="$1"
  find "$target_root" -type f -name 'etcd-snapshot-*.db' -mtime +"$RETENTION_DAYS" -delete
  find "$target_root" -type f -name 'etcd-snapshot-*.db.sha256' -mtime +"$RETENTION_DAYS" -delete
}

if mountpoint -q "$NFS_MOUNT"; then
  ensure_dir "$DEST_DIR"
  write_snapshot "$SNAPSHOT_FILE"
  purge_old "$DEST_DIR"
  echo "Backup written to NFS: $SNAPSHOT_FILE"
else
  echo "NFS mount $NFS_MOUNT is not mounted; writing to local fallback." >&2
  ensure_dir "$LOCAL_FALLBACK_DIR"
  SNAPSHOT_FILE="${LOCAL_FALLBACK_DIR}/etcd-snapshot-${TIMESTAMP}.db"
  write_snapshot "$SNAPSHOT_FILE"
  purge_old "$LOCAL_FALLBACK_DIR"
  echo "Backup written to local fallback: $SNAPSHOT_FILE"
  exit 2
fi

echo "Backup completed successfully."
