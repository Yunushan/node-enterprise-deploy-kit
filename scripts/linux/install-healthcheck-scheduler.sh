#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-config/linux/app.env}"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

PLATFORM_FAMILY="$(detect_platform_family)"
SERVICE_MANAGER_NORMALIZED="$(normalize_name "${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}")"
if [[ "$SERVICE_MANAGER_NORMALIZED" == "systemd" ]]; then
  exec bash "$REPO_ROOT/scripts/linux/install-healthcheck-timer.sh" "$CONFIG_FILE"
fi

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
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-60}"
if [[ ! "$HEALTHCHECK_INTERVAL" =~ ^[0-9]+$ || "$HEALTHCHECK_INTERVAL" -lt 1 ]]; then
  HEALTHCHECK_INTERVAL="60"
fi

prepare_healthcheck_files() {
  mkdir -p /etc/node-enterprise-deploy-kit "$HEALTHCHECK_STATE_DIR" "$LOG_DIR" "$BACKUP_DIR"
  chown root:root /etc/node-enterprise-deploy-kit "$HEALTHCHECK_STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
  chmod 0750 /etc/node-enterprise-deploy-kit "$HEALTHCHECK_STATE_DIR" "$BACKUP_DIR"
  copy_file_with_backup "$CONFIG_FILE" "$HC_CONFIG" "$BACKUP_DIR"
  copy_file_with_backup "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$HC_SCRIPT" "$BACKUP_DIR"
  chown root:root "$HC_CONFIG" "$HC_SCRIPT" 2>/dev/null || true
  chmod 0640 "$HC_CONFIG"
  chmod 0755 "$HC_SCRIPT"
}

install_launchd_scheduler() {
  require_command launchctl "launchd is required on macOS."
  prepare_healthcheck_files

  local plist_file="/Library/LaunchDaemons/${APP_NAME}-healthcheck.plist"
  render_template_file "$REPO_ROOT/templates/linux/launchd-healthcheck.plist.tpl" "$plist_file" \
    APP_NAME "$APP_NAME" \
    HEALTHCHECK_SCRIPT "$HC_SCRIPT" \
    HEALTHCHECK_CONFIG "$HC_CONFIG" \
    HEALTHCHECK_INTERVAL "$HEALTHCHECK_INTERVAL" \
    LOG_DIR "$LOG_DIR"
  chmod 0644 "$plist_file"
  chown root:wheel "$plist_file" 2>/dev/null || true

  launchctl bootout system "$plist_file" >/dev/null 2>&1 || true
  launchctl bootstrap system "$plist_file"
  launchctl enable "system/${APP_NAME}-healthcheck" 2>/dev/null || true
  launchctl kickstart -k "system/${APP_NAME}-healthcheck" 2>/dev/null || true
  launchctl print "system/${APP_NAME}-healthcheck" >/dev/null 2>&1 || true
  echo "Installed launchd healthcheck scheduler: ${APP_NAME}-healthcheck"
}

cron_schedule() {
  local interval_minutes
  interval_minutes=$(((HEALTHCHECK_INTERVAL + 59) / 60))
  if [[ "$interval_minutes" -le 1 ]]; then
    echo "* * * * *"
  elif [[ "$interval_minutes" -le 59 ]]; then
    echo "*/${interval_minutes} * * * *"
  else
    echo "0 * * * *"
  fi
}

install_cron_scheduler() {
  require_command crontab "Install cron/crontab or use SERVICE_MANAGER=systemd or launchd."
  prepare_healthcheck_files

  local marker_start marker_end current_file new_file backup_path command_line schedule
  marker_start="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:start"
  marker_end="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:end"
  current_file="$(mktemp)"
  new_file="$(mktemp)"
  if crontab -l > "$current_file" 2>/dev/null; then
    backup_path="${BACKUP_DIR}/root-crontab.$(timestamp_utc).$$.bak"
    cp -p "$current_file" "$backup_path"
    chmod 0600 "$backup_path" 2>/dev/null || true
    echo "Backed up root crontab to $backup_path"
  else
    : > "$current_file"
  fi

  awk -v start="$marker_start" -v end="$marker_end" '
    $0 == start { skipping=1; next }
    $0 == end { skipping=0; next }
    skipping != 1 { print }
  ' "$current_file" > "$new_file"
  schedule="$(cron_schedule)"
  command_line="$(shell_single_quote "$HC_SCRIPT") $(shell_single_quote "$HC_CONFIG") >/dev/null 2>&1"
  {
    printf '%s\n' "$marker_start"
    printf '%s %s\n' "$schedule" "$command_line"
    printf '%s\n' "$marker_end"
  } >> "$new_file"
  crontab "$new_file"
  rm -f "$current_file" "$new_file"
  echo "Installed cron healthcheck scheduler: ${APP_NAME}"
}

case "$SERVICE_MANAGER_NORMALIZED" in
  launchd)
    install_launchd_scheduler
    ;;
  systemv|sysv|sysvinit|initd|init-d|openrc|bsdrc|bsd-rc|rcd|rc.d)
    install_cron_scheduler
    ;;
  *)
    echo "Unsupported SERVICE_MANAGER for healthcheck scheduler: ${SERVICE_MANAGER:-}. Use systemd, systemv, openrc, launchd, or bsdrc." >&2
    exit 1
    ;;
esac
