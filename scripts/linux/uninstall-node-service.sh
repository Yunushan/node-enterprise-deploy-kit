#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
if [[ "${EUID}" -ne 0 ]]; then echo "Run as root or with sudo." >&2; exit 1; fi
systemctl disable --now "$APP_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/${APP_NAME}.service"
systemctl disable --now "${APP_NAME}-healthcheck.timer" 2>/dev/null || true
rm -f "/etc/systemd/system/${APP_NAME}-healthcheck.service" "/etc/systemd/system/${APP_NAME}-healthcheck.timer"
systemctl daemon-reload
echo "Removed systemd service and healthcheck timer for $APP_NAME. App/log directories were not deleted."
