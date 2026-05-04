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

APACHE_SITE_NAME="${APACHE_SITE_NAME:-$APP_NAME}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
TEMPLATE="$REPO_ROOT/templates/linux/apache-vhost.conf.tpl"

if command -v apache2ctl >/dev/null 2>&1; then
  APACHE_TEST_CMD=(apache2ctl configtest)
  APACHE_SERVICE="${APACHE_SERVICE:-apache2}"
  if [[ -n "${APACHE_CONFIG_DIR:-}" ]]; then
    OUT="${APACHE_CONFIG_DIR}/${APACHE_SITE_NAME}.conf"
    ENABLE_WITH_A2ENSITE="false"
  elif [[ -d /etc/apache2/sites-available ]]; then
    OUT="/etc/apache2/sites-available/${APACHE_SITE_NAME}.conf"
    ENABLE_WITH_A2ENSITE="true"
  else
    OUT="/etc/apache2/conf.d/${APACHE_SITE_NAME}.conf"
    ENABLE_WITH_A2ENSITE="false"
  fi
elif command -v httpd >/dev/null 2>&1; then
  APACHE_TEST_CMD=(httpd -t)
  if [[ -n "${APACHE_CONFIG_DIR:-}" ]]; then
    OUT="${APACHE_CONFIG_DIR}/${APACHE_SITE_NAME}.conf"
    APACHE_SERVICE="${APACHE_SERVICE:-httpd}"
  elif [[ -d /usr/local/etc/apache24/Includes ]]; then
    OUT="/usr/local/etc/apache24/Includes/${APACHE_SITE_NAME}.conf"
    APACHE_SERVICE="${APACHE_SERVICE:-apache24}"
  elif [[ -d /opt/homebrew/etc/httpd/extra ]]; then
    OUT="/opt/homebrew/etc/httpd/extra/${APACHE_SITE_NAME}.conf"
    APACHE_SERVICE="${APACHE_SERVICE:-httpd}"
  elif [[ -d /usr/local/etc/httpd/extra ]]; then
    OUT="/usr/local/etc/httpd/extra/${APACHE_SITE_NAME}.conf"
    APACHE_SERVICE="${APACHE_SERVICE:-httpd}"
  else
    OUT="/etc/httpd/conf.d/${APACHE_SITE_NAME}.conf"
    APACHE_SERVICE="${APACHE_SERVICE:-httpd}"
  fi
  ENABLE_WITH_A2ENSITE="false"
else
  echo "Apache is not installed. Install apache2/httpd first, then rerun this script." >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "$(dirname "$OUT")"

if command -v a2enmod >/dev/null 2>&1; then
  a2enmod proxy proxy_http proxy_wstunnel headers rewrite >/dev/null
fi

render_template_file "$TEMPLATE" "$OUT" \
  PUBLIC_HOSTNAME "$PUBLIC_HOSTNAME" \
  APP_PORT "$APP_PORT" \
  HEALTH_URL "$HEALTH_URL" \
  LOG_DIR "$LOG_DIR"
backup_path="$LAST_BACKUP_PATH"

if [[ "$ENABLE_WITH_A2ENSITE" == "true" ]] && command -v a2ensite >/dev/null 2>&1; then
  a2ensite "$APACHE_SITE_NAME" >/dev/null
fi

if ! "${APACHE_TEST_CMD[@]}"; then
  restore_file_from_backup "$backup_path" "$OUT"
  exit 1
fi
reload_or_restart_service "$APACHE_SERVICE" "Apache"
echo "Installed Apache reverse proxy: $OUT"
