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
if ! command -v nginx >/dev/null 2>&1; then echo "nginx is not installed. Install nginx first, then rerun this script." >&2; exit 1; fi
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
TEMPLATE="$REPO_ROOT/templates/linux/nginx-site.conf.tpl"
if [[ -z "${NGINX_CONFIG_DIR:-}" ]]; then
  case "$(detect_platform_family)" in
    freebsd|openbsd|netbsd) NGINX_CONFIG_DIR="/usr/local/etc/nginx/conf.d" ;;
    macos)
      if [[ -d /opt/homebrew/etc/nginx/servers ]]; then
        NGINX_CONFIG_DIR="/opt/homebrew/etc/nginx/servers"
      else
        NGINX_CONFIG_DIR="/usr/local/etc/nginx/servers"
      fi
      ;;
    *) NGINX_CONFIG_DIR="/etc/nginx/conf.d" ;;
  esac
fi
OUT="${NGINX_CONFIG_DIR}/${NGINX_SITE_NAME}.conf"
mkdir -p "$LOG_DIR" "$NGINX_CONFIG_DIR"
render_template_file "$TEMPLATE" "$OUT" \
  PUBLIC_HOSTNAME "$PUBLIC_HOSTNAME" \
  APP_PORT "$APP_PORT" \
  HEALTH_URL "$HEALTH_URL" \
  LOG_DIR "$LOG_DIR"
backup_path="$LAST_BACKUP_PATH"
if ! nginx -t; then
  restore_file_from_backup "$backup_path" "$OUT"
  exit 1
fi
reload_or_restart_service "${NGINX_SERVICE:-nginx}" "Nginx"
echo "Installed Nginx reverse proxy: $OUT"
