#!/usr/bin/env bash
set -euo pipefail
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
HARDENING_HELPER="$SCRIPT_DIR/runtime-hardening.sh"
if [[ ! -f "$HARDENING_HELPER" ]]; then
  HARDENING_HELPER="${SCRIPT_PATH%-healthcheck.sh}-healthcheck-hardening.sh"
fi
# shellcheck source=scripts/linux/runtime-hardening.sh
source "$HARDENING_HELPER"

# App log maintenance always runs with the application's privileges. Keeping an
# open log inode while copy-truncating avoids losing subsequent daemon output.
rotate_app_logs() {
  local directory="$1" maximum_bytes="$2" generations="$3" path size index tmp
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || { echo "App log rotation must run as a non-root account." >&2; return 1; }
  [[ -d "$directory" && ! -L "$directory" ]] || return 0
  for path in "$directory/stdout.log" "$directory/stderr.log"; do
    [[ -f "$path" && ! -L "$path" && -r "$path" && -w "$path" ]] || continue
    size="$(wc -c < "$path" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$maximum_bytes" ]] || continue
    for ((index = generations; index >= 1; index--)); do
      [[ ! -L "$path.$index" ]] || return 1
    done
    rm -f -- "$path.$generations"
    for ((index = generations - 1; index >= 1; index--)); do
      [[ ! -f "$path.$index" ]] || mv -- "$path.$index" "$path.$((index + 1))"
    done
    tmp="$(mktemp "$directory/.log-rotation.XXXXXX")"
    if cp -- "$path" "$tmp" && [[ ! -L "$path" ]]; then
      chmod 0600 -- "$tmp"
      mv -- "$tmp" "$path.1"
      : > "$path"
    else
      rm -f -- "$tmp"
      return 1
    fi
  done
}
if [[ "${1:-}" == "--rotate-app-logs" ]]; then
  [[ "$#" -eq 4 && "$3" =~ ^[0-9]+$ && "$4" =~ ^[0-9]+$ && "$3" -ge 1024 && "$4" -ge 1 && "$4" -le 100 ]] || exit 2
  rotate_app_logs "$2" "$3" "$4"
  exit
fi
CONFIG_FILE="${1:-/etc/node-enterprise-deploy-kit/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

normalize_service_manager() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

default_service_manager_for_current_host() {
  local kernel
  kernel="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$kernel" in
    darwin)
      echo "launchd"
      ;;
    freebsd|openbsd|netbsd)
      echo "bsdrc"
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
      elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
      else
        echo "systemv"
      fi
      ;;
  esac
}

SERVICE_MANAGER="${SERVICE_MANAGER:-$(default_service_manager_for_current_host)}"
APP_RUNTIME_NORMALIZED="$(echo "${APP_RUNTIME:-node}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
if [[ "$APP_RUNTIME_NORMALIZED" == "tomcat" || "$APP_RUNTIME_NORMALIZED" == "apache-tomcat" ]]; then
  SERVICE_NAME="${TOMCAT_SERVICE:-$SERVICE_NAME}"
fi
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME}}"
HEALTHCHECK_LOG_DIR="${HEALTHCHECK_LOG_DIR:-$HEALTHCHECK_STATE_DIR/logs}"
LOG_DIR_NORMALIZED="${LOG_DIR%/}"
HEALTHCHECK_STATE_DIR_NORMALIZED="${HEALTHCHECK_STATE_DIR%/}"
if [[ "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED" || "$HEALTHCHECK_STATE_DIR_NORMALIZED" == "$LOG_DIR_NORMALIZED"/* ]]; then
  echo "HEALTHCHECK_STATE_DIR must not be inside LOG_DIR because healthcheck state is root-owned control data." >&2
  exit 1
fi
hardening_prepare_control_directory "$HEALTHCHECK_STATE_DIR"
hardening_prepare_control_directory "$HEALTHCHECK_LOG_DIR"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  ROOT_GROUP="$(id -gn root)"
  chown root:"$ROOT_GROUP" "$HEALTHCHECK_STATE_DIR"
fi
STATE_FILE="$HEALTHCHECK_STATE_DIR/healthcheck.state"
LOG_FILE="$HEALTHCHECK_LOG_DIR/healthcheck.log"
hardening_assert_control_file "$STATE_FILE"
hardening_create_control_file "$LOG_FILE"
HEALTHCHECK_FAILURE_THRESHOLD="${HEALTHCHECK_FAILURE_THRESHOLD:-2}"
HEALTHCHECK_RESTART_COOLDOWN="${HEALTHCHECK_RESTART_COOLDOWN:-300}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-90}"
DIAGNOSTIC_RETENTION_DAYS="${DIAGNOSTIC_RETENTION_DAYS:-14}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HEALTHCHECK_LOG_MAX_BYTES="${HEALTHCHECK_LOG_MAX_BYTES:-10485760}"
HEALTHCHECK_LOG_GENERATIONS="${HEALTHCHECK_LOG_GENERATIONS:-7}"
APP_LOG_MAX_BYTES="${APP_LOG_MAX_BYTES:-10485760}"
APP_LOG_GENERATIONS="${APP_LOG_GENERATIONS:-7}"
PROXY_LOG_DIR="${PROXY_LOG_DIR:-/var/log/node-enterprise-deploy-kit/proxy/$APP_NAME}"
PROXY_LOG_MAX_BYTES="${PROXY_LOG_MAX_BYTES:-10485760}"
PROXY_LOG_GENERATIONS="${PROXY_LOG_GENERATIONS:-7}"
for setting_name in HEALTHCHECK_LOG_MAX_BYTES APP_LOG_MAX_BYTES PROXY_LOG_MAX_BYTES; do
  setting_value="${!setting_name}"
  [[ "$setting_value" =~ ^[0-9]+$ && "$setting_value" -ge 1024 ]] || { echo "$setting_name must be an integer of at least 1024 bytes." >&2; exit 1; }
done
for setting_name in HEALTHCHECK_LOG_GENERATIONS APP_LOG_GENERATIONS PROXY_LOG_GENERATIONS; do
  setting_value="${!setting_name}"
  [[ "$setting_value" =~ ^[0-9]+$ && "$setting_value" -ge 1 && "$setting_value" -le 100 ]] || { echo "$setting_name must be an integer from 1 through 100." >&2; exit 1; }
done
for setting_name in HEALTHCHECK_FAILURE_THRESHOLD HEALTHCHECK_RESTART_COOLDOWN HEALTHCHECK_TIMEOUT; do
  setting_value="${!setting_name}"
  [[ "$setting_value" =~ ^[0-9]+$ ]] || { echo "$setting_name must be a non-negative integer." >&2; exit 1; }
done
[[ "$HEALTHCHECK_FAILURE_THRESHOLD" -ge 1 && "$HEALTHCHECK_TIMEOUT" -ge 1 && "$HEALTHCHECK_TIMEOUT" -le 300 ]] || exit 1

# Use the orchestrator's mutex, including during the HTTP probe. A mere existence
# check would allow import to begin between the check and a service restart.
DEPLOYMENT_LOCK_ROOT="${DEPLOYMENT_LOCK_ROOT:-/var/run/node-enterprise-deploy-kit}"
hardening_prepare_control_directory "$DEPLOYMENT_LOCK_ROOT"
safe_app_name="$(printf '%s' "$APP_NAME" | sed 's/[^A-Za-z0-9_.-]/_/g')"
[[ -n "$safe_app_name" && "$safe_app_name" != "." && "$safe_app_name" != ".." ]] || exit 1
MONITOR_LOCK_PATH="${DEPLOYMENT_LOCK_ROOT%/}/${safe_app_name}.lock"
if ! (umask 077; mkdir -- "$MONITOR_LOCK_PATH") 2>/dev/null; then
  echo "Health check deferred while another operation holds the application lock."
  exit 0
fi
MONITOR_LOCK_HELD=true
MONITOR_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
cleanup_monitor_lock() {
  if [[ "$MONITOR_LOCK_HELD" == "true" ]]; then
    grep -Fxq "Token=$MONITOR_LOCK_TOKEN" "$MONITOR_LOCK_PATH/owner" || {
      echo 'Refusing to release a monitor lock whose ownership changed.' >&2
      return 1
    }
    rm -f -- "$MONITOR_LOCK_PATH/owner"
    rmdir -- "$MONITOR_LOCK_PATH"
  fi
}
trap cleanup_monitor_lock EXIT
(umask 077; printf 'AppName=%s\nProcessId=%s\nKind=healthcheck\nToken=%s\n' "$APP_NAME" "$$" "$MONITOR_LOCK_TOKEN" > "$MONITOR_LOCK_PATH/owner")
if ! hardening_assert_no_pending_transactions "$MONITOR_LOCK_PATH"; then
  echo 'Health check deferred until unfinished deployment recovery is completed.'
  exit 0
fi
hardening_rotate_log "$LOG_FILE" "$HEALTHCHECK_LOG_MAX_BYTES" "$HEALTHCHECK_LOG_GENERATIONS"
timestamp_iso_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}
log() { printf '%s %s\n' "$(timestamp_iso_utc)" "$*" >> "$LOG_FILE"; }
is_positive_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ && "$1" -gt 0 ]]
}
remove_old_files() {
  local path="$1" retention_days="$2"
  shift 2
  if ! is_positive_integer "$retention_days" || [[ ! -d "$path" ]]; then
    return
  fi
  find "$path/." ! -name . -prune -type f "$@" -mtime +"$retention_days" -print 2>/dev/null |
    while IFS= read -r old_file; do
      if rm -f "$old_file"; then
        log "RETENTION_REMOVED path=$old_file retentionDays=$retention_days"
      else
        log "RETENTION_REMOVE_FAILED path=$old_file"
      fi
    done
}
retention_cleanup() {
  # Never unlink the active stdout/stderr inode or perform root traversal under
  # application-writable directories. App log rotation runs as SERVICE_USER.
  remove_old_files "$HEALTHCHECK_LOG_DIR" "$LOG_RETENTION_DAYS" -name 'healthcheck.log.[0-9]*'
  if [[ -d "$HEALTHCHECK_STATE_DIR/diagnostics" ]]; then
    hardening_assert_trusted_directory "$HEALTHCHECK_STATE_DIR/diagnostics" || return 1
    remove_old_files "$HEALTHCHECK_STATE_DIR/diagnostics" "$DIAGNOSTIC_RETENTION_DAYS" -name 'diagnostics-*.txt'
  fi
  local backup stamp backup_epoch now retention_seconds
  if is_positive_integer "$BACKUP_RETENTION_DAYS" && [[ -d "$BACKUP_DIR" ]]; then
    hardening_assert_trusted_directory "$BACKUP_DIR" || return 1
    remove_old_files "$BACKUP_DIR" "$BACKUP_RETENTION_DAYS" -name '*.bak'
    now="$(date +%s)"
    retention_seconds=$((BACKUP_RETENTION_DAYS * 86400))
    for backup in "$BACKUP_DIR"/app.*.bak; do
      [[ -d "$backup" && ! -L "$backup" ]] || continue
      [[ "$(basename "$backup")" =~ ^app\.([0-9]{14})\.[0-9]+\.bak$ ]] || continue
      stamp="${BASH_REMATCH[1]}"
      backup_epoch="$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:8:2}:${stamp:10:2}:${stamp:12:2}" +%s 2>/dev/null || date -u -j -f '%Y%m%d%H%M%S' "$stamp" +%s 2>/dev/null)" || continue
      if (( now - backup_epoch > retention_seconds )); then
        rm -rf -- "$backup"
        log "RETENTION_REMOVED applicationBackup=$(basename "$backup") retentionDays=$BACKUP_RETENTION_DAYS"
      fi
    done
  fi
  case "$(printf '%s' "${REVERSE_PROXY:-none}" | tr '[:upper:]' '[:lower:]')" in
    nginx|apache|httpd)
      if [[ -d "$PROXY_LOG_DIR" ]]; then
        hardening_assert_trusted_directory "$PROXY_LOG_DIR" || return 1
        local proxy_log
        for proxy_log in nginx-access.log nginx-error.log apache-access.log apache-error.log; do
          hardening_copytruncate_control_log "$PROXY_LOG_DIR/$proxy_log" "$PROXY_LOG_MAX_BYTES" "$PROXY_LOG_GENERATIONS" || return 1
        done
      fi
      ;;
  esac
  rotate_application_logs
}
shell_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
rotate_application_logs() {
  [[ -n "${SERVICE_USER:-}" && "$SERVICE_USER" != "root" && -d "${LOG_DIR:-}" ]] || return 0
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    rotate_app_logs "$LOG_DIR" "$APP_LOG_MAX_BYTES" "$APP_LOG_GENERATIONS"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$SERVICE_USER" -- bash "$SCRIPT_PATH" --rotate-app-logs "$LOG_DIR" "$APP_LOG_MAX_BYTES" "$APP_LOG_GENERATIONS"
  else
    local command_text
    command_text="bash $(shell_quote "$SCRIPT_PATH") --rotate-app-logs $(shell_quote "$LOG_DIR") $APP_LOG_MAX_BYTES $APP_LOG_GENERATIONS"
    case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
      darwin|freebsd|openbsd|netbsd) su -m "$SERVICE_USER" -c "$command_text" ;;
      *) su -m -s /bin/sh "$SERVICE_USER" -c "$command_text" ;;
    esac
  fi
}
service_manager_normalized="$(normalize_service_manager "$SERVICE_MANAGER")"
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
  chmod 0600 "$tmp"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown root:"$ROOT_GROUP" "$tmp"
  fi
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
  handle_http_failure "SERVICE_NOT_RUNNING service=$SERVICE_NAME"
fi
HTTP_STATUS=""
if HTTP_STATUS="$(curl --no-location -sS --max-time "$HEALTHCHECK_TIMEOUT" --output /dev/null --write-out '%{http_code}' "$HEALTH_URL")" && [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  log "OK url=$HEALTH_URL"
  reset_failures
  exit 0
fi
handle_http_failure "HTTP_FAILED url=$HEALTH_URL status=${HTTP_STATUS:-unavailable}"
