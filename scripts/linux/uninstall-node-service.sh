#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
PLATFORM_FAMILY="$(detect_platform_family)"
SERVICE_MANAGER="${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/usr/local/sbin/${APP_NAME}-runner.sh}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HC_SCRIPT="/usr/local/sbin/${APP_NAME}-healthcheck.sh"
HC_CONFIG="/etc/node-enterprise-deploy-kit/${APP_NAME}.env"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
SERVICE_MANAGER_NORMALIZED="$(normalize_name "$SERVICE_MANAGER")"

remove_launchd_healthcheck_scheduler() {
  local plist_file="/Library/LaunchDaemons/${APP_NAME}-healthcheck.plist"
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout system "$plist_file" 2>/dev/null || true
  fi
  rm -f "$plist_file"
}

remove_cron_healthcheck_scheduler() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo "crontab not found; managed cron healthcheck entry was not checked." >&2
    return
  fi

  local marker_start marker_end current_file new_file backup_path awk_status
  marker_start="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:start"
  marker_end="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:end"
  current_file="$(mktemp)"
  new_file="$(mktemp)"

  if crontab -l > "$current_file" 2>/dev/null; then
    set +e
    awk -v start="$marker_start" -v end="$marker_end" '
      $0 == start { skipping=1; changed=1; next }
      $0 == end { skipping=0; changed=1; next }
      skipping != 1 { print }
      END { if (changed != 1) exit 7 }
    ' "$current_file" > "$new_file"
    awk_status=$?
    set -e
    case "$awk_status" in
      0)
        mkdir -p "$BACKUP_DIR"
        chmod 0750 "$BACKUP_DIR" 2>/dev/null || true
        backup_path="${BACKUP_DIR}/root-crontab.$(timestamp_utc).$$.bak"
        cp -p "$current_file" "$backup_path"
        chmod 0600 "$backup_path" 2>/dev/null || true
        crontab "$new_file"
        echo "Removed managed cron healthcheck entry for $APP_NAME."
        echo "Backed up root crontab to $backup_path"
        ;;
      7)
        echo "Managed cron healthcheck entry was not present for $APP_NAME."
        ;;
      *)
        rm -f "$current_file" "$new_file"
        echo "Failed to process root crontab for $APP_NAME." >&2
        exit 1
        ;;
    esac
  else
    echo "Root crontab was empty or unavailable; managed cron healthcheck entry was not present."
  fi

  rm -f "$current_file" "$new_file"
}

remove_healthcheck_files() {
  rm -f "$HC_CONFIG" "$HC_SCRIPT"
}

case "$SERVICE_MANAGER_NORMALIZED" in
  systemd)
    systemctl disable --now "$APP_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${APP_NAME}.service"
    systemctl disable --now "${APP_NAME}-healthcheck.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/${APP_NAME}-healthcheck.service" "/etc/systemd/system/${APP_NAME}-healthcheck.timer"
    systemctl daemon-reload
    echo "Removed systemd service and healthcheck timer for $APP_NAME. App/log directories were not deleted."
    ;;
  systemv|sysv|sysvinit|initd|init-d)
    if command -v service >/dev/null 2>&1; then service "$APP_NAME" stop 2>/dev/null || true; else "/etc/init.d/${APP_NAME}" stop 2>/dev/null || true; fi
    if command -v update-rc.d >/dev/null 2>&1; then update-rc.d -f "$APP_NAME" remove 2>/dev/null || true; fi
    if command -v chkconfig >/dev/null 2>&1; then chkconfig --del "$APP_NAME" 2>/dev/null || true; fi
    rm -f "/etc/init.d/${APP_NAME}"
    echo "Removed System V service for $APP_NAME. App/log directories were not deleted."
    ;;
  openrc)
    if command -v rc-service >/dev/null 2>&1; then rc-service "$APP_NAME" stop 2>/dev/null || true; fi
    if command -v rc-update >/dev/null 2>&1; then rc-update del "$APP_NAME" default 2>/dev/null || true; fi
    rm -f "/etc/init.d/${APP_NAME}"
    echo "Removed OpenRC service for $APP_NAME. App/log directories were not deleted."
    ;;
  launchd)
    plist_file="/Library/LaunchDaemons/${APP_NAME}.plist"
    launchctl bootout system "$plist_file" 2>/dev/null || true
    rm -f "$plist_file" "$RUNNER_SCRIPT"
    remove_launchd_healthcheck_scheduler
    echo "Removed launchd service for $APP_NAME. App/log directories were not deleted."
    ;;
  bsdrc|bsd-rc|rcd|rc.d)
    if command -v service >/dev/null 2>&1; then service "$APP_NAME" stop 2>/dev/null || true; fi
    if command -v rcctl >/dev/null 2>&1; then rcctl disable "$APP_NAME" 2>/dev/null || true; fi
    rm -f "/usr/local/etc/rc.d/${APP_NAME}" "/etc/rc.d/${APP_NAME}"
    remove_cron_healthcheck_scheduler
    echo "Removed BSD rc service for $APP_NAME. App/log directories were not deleted."
    ;;
  *)
    echo "Unsupported SERVICE_MANAGER: $SERVICE_MANAGER. Use systemd, systemv, openrc, launchd, or bsdrc." >&2
    exit 1
    ;;
esac

case "$SERVICE_MANAGER_NORMALIZED" in
  systemv|sysv|sysvinit|initd|init-d|openrc)
    remove_cron_healthcheck_scheduler
    ;;
esac
remove_healthcheck_files
