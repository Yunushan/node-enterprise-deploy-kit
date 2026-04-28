#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
SERVICE_MANAGER="${SERVICE_MANAGER:-systemd}"
OUT_DIR="${2:-$LOG_DIR/diagnostics}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/diagnostics-$(date +%Y%m%d-%H%M%S).txt"
section() { echo -e "\n===== $* =====" >> "$OUT"; }
service_status() {
  SERVICE_MANAGER_NORMALIZED="$(echo "$SERVICE_MANAGER" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  case "$SERVICE_MANAGER_NORMALIZED" in
    systemd)
      systemctl status "$APP_NAME" --no-pager >> "$OUT" 2>&1 || true
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$APP_NAME" status >> "$OUT" 2>&1 || true; else "/etc/init.d/${APP_NAME}" status >> "$OUT" 2>&1 || true; fi
      ;;
    openrc)
      rc-service "$APP_NAME" status >> "$OUT" 2>&1 || true
      ;;
    *)
      echo "Unsupported SERVICE_MANAGER=$SERVICE_MANAGER" >> "$OUT"
      ;;
  esac
}
service_logs() {
  SERVICE_MANAGER_NORMALIZED="$(echo "$SERVICE_MANAGER" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  if [[ "$SERVICE_MANAGER_NORMALIZED" == "systemd" ]]; then
    journalctl -u "$APP_NAME" -n 100 --no-pager >> "$OUT" 2>&1 || true
  else
    tail -n 100 "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log" >> "$OUT" 2>&1 || true
  fi
}
{
  echo "Diagnostics generated $(date -Is)"
  echo "APP_NAME=$APP_NAME"
  echo "APP_DIR=$APP_DIR"
  echo "APP_PORT=$APP_PORT"
  echo "HEALTH_URL=$HEALTH_URL"
  echo "SERVICE_MANAGER=$SERVICE_MANAGER"
} > "$OUT"
section "System"
uname -a >> "$OUT" || true
cat /etc/os-release >> "$OUT" 2>/dev/null || true
section "Service"
service_status
section "Processes"
ps aux | grep -E "node|$APP_NAME" | grep -v grep >> "$OUT" || true
section "Port"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":$APP_PORT" >> "$OUT" || true
section "HTTP Health"
curl -i --max-time 10 "$HEALTH_URL" >> "$OUT" 2>&1 || true
section "Service Log Tail"
service_logs
section "Log Files"
find "$LOG_DIR" -maxdepth 1 -type f -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null | sort -r | head -20 >> "$OUT" || true
echo "Diagnostics written to: $OUT"
