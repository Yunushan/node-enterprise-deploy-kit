#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
if ! command -v nginx >/dev/null 2>&1; then echo "nginx is not installed. Install nginx first, then rerun this script." >&2; exit 1; fi
reload_service() {
  local service_name="$1"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${service_name}.service" >/dev/null 2>&1; then
    systemctl reload "$service_name" || systemctl restart "$service_name"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$service_name" reload || rc-service "$service_name" restart
  elif command -v service >/dev/null 2>&1; then
    service "$service_name" reload || service "$service_name" restart
  elif [[ -x "/etc/init.d/$service_name" ]]; then
    "/etc/init.d/$service_name" reload || "/etc/init.d/$service_name" restart
  else
    echo "Nginx config installed, but no service control command was found. Reload Nginx manually." >&2
  fi
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/linux/nginx-site.conf.tpl"
OUT="/etc/nginx/conf.d/${NGINX_SITE_NAME}.conf"
mkdir -p "$LOG_DIR"
sed \
  -e "s|{{PUBLIC_HOSTNAME}}|${PUBLIC_HOSTNAME}|g" \
  -e "s|{{APP_PORT}}|${APP_PORT}|g" \
  -e "s|{{HEALTH_URL}}|${HEALTH_URL}|g" \
  -e "s|{{LOG_DIR}}|${LOG_DIR}|g" \
  "$TEMPLATE" > "$OUT"
nginx -t
reload_service nginx
echo "Installed Nginx reverse proxy: $OUT"
