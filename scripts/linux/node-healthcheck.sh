#!/usr/bin/env bash
set -euo pipefail
CONFIG_FILE="${1:-/etc/node-enterprise-deploy-kit/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
SERVICE_MANAGER="${SERVICE_MANAGER:-systemd}"
APP_RUNTIME_NORMALIZED="$(echo "${APP_RUNTIME:-node}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
if [[ "$APP_RUNTIME_NORMALIZED" == "tomcat" || "$APP_RUNTIME_NORMALIZED" == "apache-tomcat" ]]; then
  SERVICE_NAME="${TOMCAT_SERVICE:-$SERVICE_NAME}"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/healthcheck.log"
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME}}"
LOG_DIR_NORMALIZED="${LOG_DIR%/}"
HEALTHCHECK_STATE_DIR_NORMALIZED="${HEALTHCHECK_STATE_DIR%/}"
if [[ "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED" || "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED"/* ]]; then
  echo "HEALTHCHECK_STATE_DIR must not be inside LOG_DIR because healthcheck state is root-owned control data." >&2
  exit 1
fi
mkdir -p "$HEALTHCHECK_STATE_DIR"
chmod 0750 "$HEALTHCHECK_STATE_DIR" 2>/dev/null || true
chown root:root "$HEALTHCHECK_STATE_DIR" 2>/dev/null || true
STATE_FILE="$HEALTHCHECK_STATE_DIR/healthcheck.state"
HEALTHCHECK_FAILURE_THRESHOLD="${HEALTHCHECK_FAILURE_THRESHOLD:-2}"
HEALTHCHECK_RESTART_COOLDOWN="${HEALTHCHECK_RESTART_COOLDOWN:-300}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-90}"
DIAGNOSTIC_RETENTION_DAYS="${DIAGNOSTIC_RETENTION_DAYS:-14}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
log() { echo "$(date -Is) $*" >> "$LOG_FILE"; }
is_positive_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ && "$1" -gt 0 ]]
}
remove_old_files() {
  local path="$1" retention_days="$2"
  shift 2
  if ! is_positive_integer "$retention_days" || [[ ! -d "$path" ]]; then
    return
  fi
  find "$path" -type f "$@" -mtime +"$retention_days" -print 2>/dev/null |
    while IFS= read -r old_file; do
      if rm -f "$old_file"; then
        log "RETENTION_REMOVED path=$old_file retentionDays=$retention_days"
      else
        log "RETENTION_REMOVE_FAILED path=$old_file"
      fi
    done
}
retention_cleanup() {
  remove_old_files "$LOG_DIR" "$LOG_RETENTION_DAYS" \( -name '*.log' -o -name '*.out' -o -name '*.err' \)
  remove_old_files "$LOG_DIR/diagnostics" "$DIAGNOSTIC_RETENTION_DAYS" \( -name '*.txt' -o -name '*.log' \)
  remove_old_files "$BACKUP_DIR" "$BACKUP_RETENTION_DAYS" -name '*.bak'
}
service_manager_normalized="$(echo "$SERVICE_MANAGER" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
CONSECUTIVE_FAILURES=0
LAST_RESTART_EPOCH=0
LAST_SUCCESS_EPOCH=0
LAST_FAILURE_EPOCH=0
LAST_CHECK_EPOCH=0
read_state() {
  local key value
  if [[ ! -f "$STATE_FILE" ]]; then
    return
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      CONSECUTIVE_FAILURES|LAST_RESTART_EPOCH|LAST_SUCCESS_EPOCH|LAST_FAILURE_EPOCH|LAST_CHECK_EPOCH)
        if [[ "$value" =~ ^[0-9]+$ ]]; then
          printf -v "$key" '%s' "$value"
        else
          log "STATE_IGNORED key=$key reason=non_integer"
        fi
        ;;
    esac
  done < "$STATE_FILE"
}
read_state
retention_cleanup
write_state() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  {
    echo "CONSECUTIVE_FAILURES=${CONSECUTIVE_FAILURES:-0}"
    echo "LAST_RESTART_EPOCH=${LAST_RESTART_EPOCH:-0}"
    echo "LAST_SUCCESS_EPOCH=${LAST_SUCCESS_EPOCH:-0}"
    echo "LAST_FAILURE_EPOCH=${LAST_FAILURE_EPOCH:-0}"
    echo "LAST_CHECK_EPOCH=${LAST_CHECK_EPOCH:-0}"
  } > "$tmp"
  chmod 0640 "$tmp" 2>/dev/null || true
  chown root:root "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATE_FILE"
}
reset_failures() {
  LAST_CHECK_EPOCH="$(date +%s)"
  LAST_SUCCESS_EPOCH="$LAST_CHECK_EPOCH"
  CONSECUTIVE_FAILURES=0
  write_state
}
service_is_active() {
  case "$service_manager_normalized" in
    systemd)
      systemctl is-active --quiet "$SERVICE_NAME"
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" status >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" status >/dev/null 2>&1; fi
      ;;
    openrc)
      rc-service "$SERVICE_NAME" status >/dev/null 2>&1
      ;;
    launchd)
      launchctl print "system/${SERVICE_NAME}" >/dev/null 2>&1
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v service >/dev/null 2>&1; then
        service "$SERVICE_NAME" status >/dev/null 2>&1
      elif command -v rcctl >/dev/null 2>&1; then
        rcctl check "$SERVICE_NAME" >/dev/null 2>&1
      elif [[ -x "/usr/local/etc/rc.d/${SERVICE_NAME}" ]]; then
        "/usr/local/etc/rc.d/${SERVICE_NAME}" status >/dev/null 2>&1
      else
        "/etc/rc.d/${SERVICE_NAME}" status >/dev/null 2>&1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}
restart_service() {
  case "$service_manager_normalized" in
    systemd)
      systemctl restart "$SERVICE_NAME" || true
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" restart || true; else "/etc/init.d/${SERVICE_NAME}" restart || true; fi
      ;;
    openrc)
      rc-service "$SERVICE_NAME" restart || true
      ;;
    launchd)
      launchctl kickstart -k "system/${SERVICE_NAME}" || true
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v service >/dev/null 2>&1; then
        service "$SERVICE_NAME" restart || true
      elif command -v rcctl >/dev/null 2>&1; then
        rcctl restart "$SERVICE_NAME" || true
      elif [[ -x "/usr/local/etc/rc.d/${SERVICE_NAME}" ]]; then
        "/usr/local/etc/rc.d/${SERVICE_NAME}" restart || true
      else
        "/etc/rc.d/${SERVICE_NAME}" restart || true
      fi
      ;;
    *)
      log "UNSUPPORTED_SERVICE_MANAGER value=$SERVICE_MANAGER"
      ;;
  esac
}
handle_http_failure() {
  local reason="$1" now
  now="$(date +%s)"
  LAST_CHECK_EPOCH="$now"
  LAST_FAILURE_EPOCH="$now"
  CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  if [[ "$CONSECUTIVE_FAILURES" -lt "$HEALTHCHECK_FAILURE_THRESHOLD" ]]; then
    log "FAILED reason=$reason consecutiveFailures=$CONSECUTIVE_FAILURES threshold=$HEALTHCHECK_FAILURE_THRESHOLD"
    write_state
    exit 1
  fi
  if [[ "$LAST_RESTART_EPOCH" -gt 0 && $((now - LAST_RESTART_EPOCH)) -lt "$HEALTHCHECK_RESTART_COOLDOWN" ]]; then
    log "RESTART_SUPPRESSED_COOLDOWN reason=$reason cooldownSeconds=$HEALTHCHECK_RESTART_COOLDOWN"
    write_state
    exit 1
  fi
  log "RESTARTING_SERVICE reason=$reason consecutiveFailures=$CONSECUTIVE_FAILURES"
  restart_service
  LAST_RESTART_EPOCH="$now"
  CONSECUTIVE_FAILURES=0
  write_state
  exit 1
}
if ! service_is_active; then
  log "SERVICE_NOT_RUNNING restarting service=$SERVICE_NAME"
  restart_service
  LAST_RESTART_EPOCH="$(date +%s)"
  reset_failures
  sleep 5
fi
if curl -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTH_URL" >/dev/null; then
  log "OK url=$HEALTH_URL"
  reset_failures
  exit 0
fi
handle_http_failure "HTTP_FAILED url=$HEALTH_URL"
