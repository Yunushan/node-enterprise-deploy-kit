#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
if ! command -v nginx >/dev/null 2>&1; then echo "nginx is not installed. Install nginx first, then rerun this script." >&2; exit 1; fi
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
systemctl reload nginx
echo "Installed Nginx reverse proxy: $OUT"
