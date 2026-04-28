#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
OUT_DIR="${2:-$LOG_DIR/diagnostics}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/diagnostics-$(date +%Y%m%d-%H%M%S).txt"
section() { echo -e "\n===== $* =====" >> "$OUT"; }
{
  echo "Diagnostics generated $(date -Is)"
  echo "APP_NAME=$APP_NAME"
  echo "APP_DIR=$APP_DIR"
  echo "APP_PORT=$APP_PORT"
  echo "HEALTH_URL=$HEALTH_URL"
} > "$OUT"
section "System"
uname -a >> "$OUT" || true
cat /etc/os-release >> "$OUT" 2>/dev/null || true
section "Service"
systemctl status "$APP_NAME" --no-pager >> "$OUT" 2>&1 || true
section "Processes"
ps aux | grep -E "node|$APP_NAME" | grep -v grep >> "$OUT" || true
section "Port"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":$APP_PORT" >> "$OUT" || true
section "HTTP Health"
curl -i --max-time 10 "$HEALTH_URL" >> "$OUT" 2>&1 || true
section "Journal Tail"
journalctl -u "$APP_NAME" -n 100 --no-pager >> "$OUT" 2>&1 || true
section "Log Files"
find "$LOG_DIR" -maxdepth 1 -type f -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null | sort -r | head -20 >> "$OUT" || true
echo "Diagnostics written to: $OUT"
