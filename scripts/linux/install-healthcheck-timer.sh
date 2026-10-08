#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
# shellcheck source=scripts/linux/runtime-hardening.sh
source "$REPO_ROOT/scripts/linux/runtime-hardening.sh"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-60}"
if [[ ! "$HEALTHCHECK_INTERVAL" =~ ^[0-9]+$ || "$HEALTHCHECK_INTERVAL" -lt 1 ]]; then
  HEALTHCHECK_INTERVAL=60
fi
# Consumed by managed_mutation_exit in the sourced installer transaction helper.
# shellcheck disable=SC2034
MANAGED_MUTATION_REPLACES_HEALTH_SCHEDULER=true
managed_mutation_begin
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME}}"
ROOT_GROUP="$(root_group_name)"
LOG_DIR_NORMALIZED="${LOG_DIR%/}"
HEALTHCHECK_STATE_DIR_NORMALIZED="${HEALTHCHECK_STATE_DIR%/}"
if [[ "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED" || "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED"/* ]]; then
  echo "HEALTHCHECK_STATE_DIR must not be inside LOG_DIR because healthcheck state is root-owned control data." >&2
  exit 1
fi
HC_SCRIPT="/usr/local/sbin/${APP_NAME}-healthcheck.sh"
HC_HELPER="/usr/local/sbin/${APP_NAME}-healthcheck-hardening.sh"
HC_CONFIG="/etc/node-enterprise-deploy-kit/${APP_NAME}.env"
HEALTHCHECK_LOG_DIR="${HEALTHCHECK_LOG_DIR:-$HEALTHCHECK_STATE_DIR/logs}"
hardening_prepare_control_directory /etc/node-enterprise-deploy-kit
hardening_prepare_control_directory "$HEALTHCHECK_STATE_DIR"
hardening_prepare_control_directory "$HEALTHCHECK_LOG_DIR"
hardening_prepare_control_directory "$BACKUP_DIR"
copy_file_with_backup "$CONFIG_FILE" "$HC_CONFIG" "$BACKUP_DIR"
copy_file_with_backup "$REPO_ROOT/scripts/linux/runtime-hardening.sh" "$HC_HELPER" "$BACKUP_DIR"
copy_file_with_backup "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$HC_SCRIPT" "$BACKUP_DIR"
chown root:"$ROOT_GROUP" "$HC_CONFIG" "$HC_SCRIPT" "$HC_HELPER"
chmod 0640 "$HC_CONFIG"
chmod 0755 "$HC_SCRIPT"
chmod 0644 "$HC_HELPER"
render_template_file "$REPO_ROOT/templates/linux/healthcheck.service.tpl" "/etc/systemd/system/${APP_NAME}-healthcheck.service" \
  APP_NAME "$APP_NAME" \
  APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
  HEALTHCHECK_COMMAND "$HC_SCRIPT $HC_CONFIG" \
  LOG_DIR "$HEALTHCHECK_LOG_DIR" \
  BACKUP_DIR "$BACKUP_DIR" \
  HEALTHCHECK_STATE_DIR "$HEALTHCHECK_STATE_DIR"
render_template_file "$REPO_ROOT/templates/linux/healthcheck.timer.tpl" "/etc/systemd/system/${APP_NAME}-healthcheck.timer" \
  APP_NAME "$APP_NAME" \
  APP_DISPLAY_NAME "$APP_DISPLAY_NAME" \
  HEALTHCHECK_INTERVAL "$HEALTHCHECK_INTERVAL"
systemctl daemon-reload
systemctl enable --now "${APP_NAME}-healthcheck.timer"
systemctl is-enabled --quiet "${APP_NAME}-healthcheck.timer"
systemctl is-active --quiet "${APP_NAME}-healthcheck.timer"
echo "Installed healthcheck timer: ${APP_NAME}-healthcheck.timer"
