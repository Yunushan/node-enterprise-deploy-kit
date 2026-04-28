#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi

APACHE_SITE_NAME="${APACHE_SITE_NAME:-$APP_NAME}"

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
    echo "Apache config installed, but no service control command was found. Reload Apache manually." >&2
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/linux/apache-vhost.conf.tpl"

if command -v apache2ctl >/dev/null 2>&1; then
  APACHE_TEST_CMD=(apache2ctl configtest)
  APACHE_SERVICE="${APACHE_SERVICE:-apache2}"
  if [[ -d /etc/apache2/sites-available ]]; then
    OUT="/etc/apache2/sites-available/${APACHE_SITE_NAME}.conf"
    ENABLE_WITH_A2ENSITE="true"
  else
    OUT="/etc/apache2/conf.d/${APACHE_SITE_NAME}.conf"
    ENABLE_WITH_A2ENSITE="false"
  fi
elif command -v httpd >/dev/null 2>&1; then
  APACHE_TEST_CMD=(httpd -t)
  APACHE_SERVICE="${APACHE_SERVICE:-httpd}"
  OUT="/etc/httpd/conf.d/${APACHE_SITE_NAME}.conf"
  ENABLE_WITH_A2ENSITE="false"
else
  echo "Apache is not installed. Install apache2/httpd first, then rerun this script." >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$(dirname "$OUT")"

if command -v a2enmod >/dev/null 2>&1; then
  a2enmod proxy proxy_http proxy_wstunnel headers rewrite >/dev/null
fi

sed \
  -e "s|{{PUBLIC_HOSTNAME}}|${PUBLIC_HOSTNAME}|g" \
  -e "s|{{APP_PORT}}|${APP_PORT}|g" \
  -e "s|{{HEALTH_URL}}|${HEALTH_URL}|g" \
  -e "s|{{LOG_DIR}}|${LOG_DIR}|g" \
  "$TEMPLATE" > "$OUT"

if [[ "$ENABLE_WITH_A2ENSITE" == "true" ]] && command -v a2ensite >/dev/null 2>&1; then
  a2ensite "$APACHE_SITE_NAME" >/dev/null
fi

"${APACHE_TEST_CMD[@]}"
reload_service "$APACHE_SERVICE"
echo "Installed Apache reverse proxy: $OUT"
