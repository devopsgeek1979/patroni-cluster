#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  echo "Usage: $0 <db1|db2|db3|haproxy> [repo_root] [--check-only] [--restart]"
}

ROLE="${1:-}"
shift || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=false
RESTART=false

if [[ -n "${1:-}" && "${1}" != --* ]]; then
  REPO_ROOT="${1}"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=true
      ;;
    --restart)
      RESTART=true
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
  shift
done

if [[ -z "$ROLE" ]]; then
  print_usage
  exit 1
fi

ensure_exists() {
  local file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    echo "Required file not found: $file_path"
    exit 1
  fi
}

validate_target_content() {
  local role="$1"
  local target_file="$2"

  ensure_exists "$target_file"

  if [[ "$role" == "haproxy" ]]; then
    grep -q "listen primary" "$target_file"
    grep -q "listen standby" "$target_file"
  else
    grep -q "^scope:" "$target_file"
    grep -q "^name:" "$target_file"
    grep -q "connect_address:" "$target_file"
  fi
}

copy_with_permissions() {
  local source_file="$1"
  local target_dir="$2"
  local target_file="$3"
  local owner_group="$4"
  local mode="$5"

  ensure_exists "$source_file"
  sudo mkdir -p "$target_dir"
  sudo cp "$source_file" "$target_file"
  sudo chown "$owner_group" "$target_file"
  sudo chmod "$mode" "$target_file"
  echo "Deployed $source_file -> $target_file"
}

restart_service() {
  local service_name="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not available; skipping restart for $service_name"
    return
  fi

  sudo systemctl restart "$service_name"
  sudo systemctl status "$service_name" --no-pager
}

SOURCE_FILE=""
TARGET_FILE=""
TARGET_DIR=""
OWNER_GROUP=""
FILE_MODE=""
SERVICE_NAME=""

case "$ROLE" in
  db1)
    SOURCE_FILE="$REPO_ROOT/configs/patroni-yml/patroni-db1.yml"
    TARGET_DIR="/etc/patroni"
    TARGET_FILE="/etc/patroni/patroni.yml"
    OWNER_GROUP="postgres:postgres"
    FILE_MODE="640"
    SERVICE_NAME="patroni"
    ;;
  db2)
    SOURCE_FILE="$REPO_ROOT/configs/patroni-yml/patroni-db2.yml"
    TARGET_DIR="/etc/patroni"
    TARGET_FILE="/etc/patroni/patroni.yml"
    OWNER_GROUP="postgres:postgres"
    FILE_MODE="640"
    SERVICE_NAME="patroni"
    ;;
  db3)
    SOURCE_FILE="$REPO_ROOT/configs/patroni-yml/patroni-db3.yml"
    TARGET_DIR="/etc/patroni"
    TARGET_FILE="/etc/patroni/patroni.yml"
    OWNER_GROUP="postgres:postgres"
    FILE_MODE="640"
    SERVICE_NAME="patroni"
    ;;
  haproxy)
    SOURCE_FILE="$REPO_ROOT/configs/haproxy/haproxy.cfg"
    TARGET_DIR="/etc/haproxy"
    TARGET_FILE="/etc/haproxy/haproxy.cfg"
    OWNER_GROUP="root:root"
    FILE_MODE="644"
    SERVICE_NAME="haproxy"
    ;;
  *)
    echo "Invalid role: $ROLE"
    print_usage
    exit 1
    ;;
esac

ensure_exists "$SOURCE_FILE"

if [[ "$CHECK_ONLY" == true ]]; then
  echo "Check mode enabled: validating source and target files"
  validate_target_content "$ROLE" "$TARGET_FILE"
  echo "Check passed for role $ROLE"
  exit 0
fi

copy_with_permissions "$SOURCE_FILE" "$TARGET_DIR" "$TARGET_FILE" "$OWNER_GROUP" "$FILE_MODE"
validate_target_content "$ROLE" "$TARGET_FILE"

if [[ "$RESTART" == true ]]; then
  restart_service "$SERVICE_NAME"
fi

echo "Done."
