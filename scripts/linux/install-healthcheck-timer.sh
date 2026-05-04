#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HC_SCRIPT="/usr/local/sbin/${APP_NAME}-healthcheck.sh"
HC_CONFIG="/etc/node-enterprise-deploy-kit/${APP_NAME}.env"
mkdir -p /etc/node-enterprise-deploy-kit
copy_file_with_backup "$CONFIG_FILE" "$HC_CONFIG" "$BACKUP_DIR"
copy_file_with_backup "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$HC_SCRIPT" "$BACKUP_DIR"
chmod 0755 "$HC_SCRIPT"
render_template_file "$REPO_ROOT/templates/linux/healthcheck.service.tpl" "/etc/systemd/system/${APP_NAME}-healthcheck.service" \
  APP_NAME "$APP_NAME" \
  APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
  HEALTHCHECK_COMMAND "$HC_SCRIPT $HC_CONFIG"
render_template_file "$REPO_ROOT/templates/linux/healthcheck.timer.tpl" "/etc/systemd/system/${APP_NAME}-healthcheck.timer" \
  APP_NAME "$APP_NAME" \
  APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
  HEALTHCHECK_INTERVAL "$HEALTHCHECK_INTERVAL"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}-healthcheck.timer"
systemctl list-timers --all | grep "$APP_NAME" || true
echo "Installed healthcheck timer: ${APP_NAME}-healthcheck.timer"
