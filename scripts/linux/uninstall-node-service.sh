#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
SERVICE_MANAGER="${SERVICE_MANAGER:-systemd}"
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/usr/local/sbin/${APP_NAME}-runner.sh}"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
SERVICE_MANAGER_NORMALIZED="$(echo "$SERVICE_MANAGER" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
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
    echo "Removed launchd service for $APP_NAME. App/log directories were not deleted."
    ;;
  bsdrc|bsd-rc|rcd|rc.d)
    if command -v service >/dev/null 2>&1; then service "$APP_NAME" stop 2>/dev/null || true; fi
    if command -v rcctl >/dev/null 2>&1; then rcctl disable "$APP_NAME" 2>/dev/null || true; fi
    rm -f "/usr/local/etc/rc.d/${APP_NAME}" "/etc/rc.d/${APP_NAME}"
    echo "Removed BSD rc service for $APP_NAME. App/log directories were not deleted."
    ;;
  *)
    echo "Unsupported SERVICE_MANAGER: $SERVICE_MANAGER. Use systemd, systemv, openrc, launchd, or bsdrc." >&2
    exit 1
    ;;
esac
