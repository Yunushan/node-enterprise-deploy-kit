#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-config/linux/app.env}"
CONFIG_FILE="$(resolve_config_path "$REPO_ROOT" "$CONFIG_FILE")"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
if ! command -v haproxy >/dev/null 2>&1; then echo "HAProxy is not installed. Install haproxy first, then rerun this script." >&2; exit 1; fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HAPROXY_SERVICE="${HAPROXY_SERVICE:-haproxy}"
HAPROXY_CONFIG_FILE="${HAPROXY_CONFIG_FILE:-/etc/haproxy/haproxy.cfg}"
HAPROXY_BIND="${HAPROXY_BIND:-*:80}"
HAPROXY_FRONTEND_NAME="${HAPROXY_FRONTEND_NAME:-${APP_NAME}_frontend}"
HAPROXY_BACKEND_NAME="${HAPROXY_BACKEND_NAME:-${APP_NAME}_backend}"
HEALTHCHECK_PATH="${HEALTHCHECK_PATH:-/health}"
TEMPLATE="$REPO_ROOT/templates/linux/haproxy.cfg.tpl"

mkdir -p "$LOG_DIR" "$(dirname "$HAPROXY_CONFIG_FILE")"
render_template_file "$TEMPLATE" "$HAPROXY_CONFIG_FILE" \
  APP_NAME "$APP_NAME" \
  APP_PORT "$APP_PORT" \
  HAPROXY_BIND "$HAPROXY_BIND" \
  HAPROXY_FRONTEND_NAME "$HAPROXY_FRONTEND_NAME" \
  HAPROXY_BACKEND_NAME "$HAPROXY_BACKEND_NAME" \
  HEALTHCHECK_PATH "$HEALTHCHECK_PATH"
backup_path="$LAST_BACKUP_PATH"

if ! haproxy -c -f "$HAPROXY_CONFIG_FILE"; then
  restore_file_from_backup "$backup_path" "$HAPROXY_CONFIG_FILE"
  exit 1
fi

reload_or_restart_service "$HAPROXY_SERVICE" "HAProxy"
echo "Installed HAProxy reverse proxy: $HAPROXY_CONFIG_FILE"
