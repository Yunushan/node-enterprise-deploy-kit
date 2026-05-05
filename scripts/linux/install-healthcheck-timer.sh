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
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME}}"
LOG_DIR_NORMALIZED="${LOG_DIR%/}"
HEALTHCHECK_STATE_DIR_NORMALIZED="${HEALTHCHECK_STATE_DIR%/}"
if [[ "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED" || "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED"/* ]]; then
  echo "HEALTHCHECK_STATE_DIR must not be inside LOG_DIR because healthcheck state is root-owned control data." >&2
  exit 1
fi
HC_SCRIPT="/usr/local/sbin/${APP_NAME}-healthcheck.sh"
HC_CONFIG="/etc/node-enterprise-deploy-kit/${APP_NAME}.env"
mkdir -p /etc/node-enterprise-deploy-kit "$HEALTHCHECK_STATE_DIR" "$LOG_DIR" "$BACKUP_DIR"
chown root:root /etc/node-enterprise-deploy-kit "$HEALTHCHECK_STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
chmod 0750 /etc/node-enterprise-deploy-kit "$HEALTHCHECK_STATE_DIR" "$BACKUP_DIR"
copy_file_with_backup "$CONFIG_FILE" "$HC_CONFIG" "$BACKUP_DIR"
copy_file_with_backup "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$HC_SCRIPT" "$BACKUP_DIR"
chown root:root "$HC_CONFIG" "$HC_SCRIPT" 2>/dev/null || true
chmod 0640 "$HC_CONFIG"
chmod 0755 "$HC_SCRIPT"
render_template_file "$REPO_ROOT/templates/linux/healthcheck.service.tpl" "/etc/systemd/system/${APP_NAME}-healthcheck.service" \
  APP_NAME "$APP_NAME" \
  APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
  HEALTHCHECK_COMMAND "$HC_SCRIPT $HC_CONFIG" \
  LOG_DIR "$LOG_DIR" \
  BACKUP_DIR "$BACKUP_DIR" \
  HEALTHCHECK_STATE_DIR "$HEALTHCHECK_STATE_DIR"
render_template_file "$REPO_ROOT/templates/linux/healthcheck.timer.tpl" "/etc/systemd/system/${APP_NAME}-healthcheck.timer" \
  APP_NAME "$APP_NAME" \
  APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
  HEALTHCHECK_INTERVAL "$HEALTHCHECK_INTERVAL"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}-healthcheck.timer"
systemctl list-timers --all | grep "$APP_NAME" || true
echo "Installed healthcheck timer: ${APP_NAME}-healthcheck.timer"
