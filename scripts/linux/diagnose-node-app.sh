#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
SERVICE_MANAGER="${SERVICE_MANAGER:-systemd}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
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
    launchd)
      launchctl print "system/${APP_NAME}" >> "$OUT" 2>&1 || true
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v service >/dev/null 2>&1; then
        service "$APP_NAME" status >> "$OUT" 2>&1 || true
      elif command -v rcctl >/dev/null 2>&1; then
        rcctl check "$APP_NAME" >> "$OUT" 2>&1 || true
      elif [[ -x "/usr/local/etc/rc.d/${APP_NAME}" ]]; then
        "/usr/local/etc/rc.d/${APP_NAME}" status >> "$OUT" 2>&1 || true
      else
        "/etc/rc.d/${APP_NAME}" status >> "$OUT" 2>&1 || true
      fi
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
  echo "APP_RUNTIME=${APP_RUNTIME:-node}"
  echo "REVERSE_PROXY=${REVERSE_PROXY:-none}"
} > "$OUT"
section "System"
uname -a >> "$OUT" || true
cat /etc/os-release >> "$OUT" 2>/dev/null || true
section "Service"
service_status
section "Processes"
ps aux | grep -E "node|java|tomcat|haproxy|traefik|nginx|httpd|apache|$APP_NAME" | grep -v grep >> "$OUT" || true
section "Port"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":$APP_PORT" >> "$OUT" || true
section "HTTP Health"
curl -i --max-time 10 "$HEALTH_URL" >> "$OUT" 2>&1 || true
section "Reverse Proxy"
case "$(echo "${REVERSE_PROXY:-none}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')" in
  nginx)
    nginx -t >> "$OUT" 2>&1 || true
    ;;
  apache|httpd)
    apache2ctl configtest >> "$OUT" 2>&1 || httpd -t >> "$OUT" 2>&1 || true
    ;;
  haproxy)
    haproxy -c -f "${HAPROXY_CONFIG_FILE:-/etc/haproxy/haproxy.cfg}" >> "$OUT" 2>&1 || true
    ;;
  traefik)
    if [[ -n "${TRAEFIK_STATIC_CONFIG:-}" && -f "$TRAEFIK_STATIC_CONFIG" ]]; then
      traefik check --configFile="$TRAEFIK_STATIC_CONFIG" >> "$OUT" 2>&1 || true
    fi
    ls -l "${TRAEFIK_DYNAMIC_FILE:-/etc/traefik/dynamic/${APP_NAME}.yml}" >> "$OUT" 2>&1 || true
    ;;
esac
section "Health History"
if [[ -f "$LOG_DIR/healthcheck.state" ]]; then
  grep -E '^(CONSECUTIVE_FAILURES|LAST_CHECK_EPOCH|LAST_SUCCESS_EPOCH|LAST_FAILURE_EPOCH|LAST_RESTART_EPOCH)=' "$LOG_DIR/healthcheck.state" >> "$OUT" || true
else
  echo "No healthcheck.state file found." >> "$OUT"
fi
if [[ -f "$LOG_DIR/healthcheck.log" ]]; then
  {
    echo "healthcheck.log lastWrite=$(date -r "$LOG_DIR/healthcheck.log" -Is 2>/dev/null || true) sizeBytes=$(wc -c < "$LOG_DIR/healthcheck.log" 2>/dev/null || echo 0)"
    echo "OK count=$(grep -c ' OK ' "$LOG_DIR/healthcheck.log" 2>/dev/null || echo 0)"
    echo "FAILED count=$(grep -Ec ' FAILED|FAILED_THRESHOLD|HTTP_FAILED|SERVICE_NOT_RUNNING' "$LOG_DIR/healthcheck.log" 2>/dev/null || echo 0)"
    echo "RESTART count=$(grep -Ec 'RESTARTING_SERVICE|SERVICE_NOT_RUNNING' "$LOG_DIR/healthcheck.log" 2>/dev/null || echo 0)"
    echo "RESTART_SUPPRESSED count=$(grep -c 'RESTART_SUPPRESSED_COOLDOWN' "$LOG_DIR/healthcheck.log" 2>/dev/null || echo 0)"
  } >> "$OUT"
else
  echo "No healthcheck.log file found." >> "$OUT"
fi
section "Service Log Tail"
service_logs
section "Log Files"
find "$LOG_DIR" -maxdepth 1 -type f -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null | sort -r | head -20 >> "$OUT" || true
section "Retention And Backups"
{
  echo "LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-30}"
  echo "BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-90}"
  echo "DIAGNOSTIC_RETENTION_DAYS=${DIAGNOSTIC_RETENTION_DAYS:-14}"
  echo "BACKUP_DIR=$BACKUP_DIR"
} >> "$OUT"
find "$BACKUP_DIR" -maxdepth 1 -type f -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null | sort -r | head -20 >> "$OUT" || true
echo "Diagnostics written to: $OUT"
