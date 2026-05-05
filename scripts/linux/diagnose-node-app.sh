#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/diagnose-node-app.sh [config.env] [output-dir] [options]

Options:
  --output-dir <path>       Write diagnostics under this directory.
  --include-raw-details     Include raw service status, process args, HTTP body,
                            and service log tails. May expose secrets.
  --include-raw-logs        Alias for --include-raw-details.
  -h, --help                Show this help.
USAGE
}

CONFIG_FILE=""
OUT_DIR=""
INCLUDE_RAW_DETAILS="false"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output-dir)
      shift
      if [[ "$#" -eq 0 ]]; then echo "--output-dir requires a path." >&2; exit 2; fi
      OUT_DIR="$1"
      ;;
    --include-raw-details|--include-raw-logs)
      INCLUDE_RAW_DETAILS="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="$1"
      elif [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
  shift
done

CONFIG_FILE="${CONFIG_FILE:-config/linux/app.env}"
if [[ ! -f "$CONFIG_FILE" ]]; then echo "Config not found: $CONFIG_FILE" >&2; exit 1; fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

SERVICE_MANAGER="${SERVICE_MANAGER:-systemd}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${APP_NAME}}"
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME}}"
HEALTHCHECK_STATE_FILE="$HEALTHCHECK_STATE_DIR/healthcheck.state"
OUT_DIR="${OUT_DIR:-$LOG_DIR/diagnostics}"
APP_RUNTIME_NORMALIZED="$(echo "${APP_RUNTIME:-node}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
if [[ "$APP_RUNTIME_NORMALIZED" == "tomcat" || "$APP_RUNTIME_NORMALIZED" == "apache-tomcat" ]]; then
  SERVICE_NAME="${TOMCAT_SERVICE:-$SERVICE_NAME}"
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/diagnostics-$(date +%Y%m%d-%H%M%S).txt"

section() { printf '\n===== %s =====\n' "$*" >> "$OUT"; }

normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

safe_url() {
  local url="${1:-}"
  url="${url%%#*}"
  url="${url%%\?*}"
  printf '%s\n' "$url" | sed -E 's#(https?://)[^/@]+@#\1[redacted]@#'
}

service_status_summary() {
  local service_manager_normalized
  service_manager_normalized="$(normalize_name "$SERVICE_MANAGER")"
  echo "ServiceName=$SERVICE_NAME"
  echo "ServiceManager=$service_manager_normalized"

  case "$service_manager_normalized" in
    systemd)
      if command -v systemctl >/dev/null 2>&1; then
        echo "IsActive=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
        echo "IsEnabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
        systemctl show "$SERVICE_NAME" --no-pager \
          --property=Id,LoadState,ActiveState,SubState,UnitFileState,MainPID,ExecMainCode,ExecMainStatus,NRestarts,ActiveEnterTimestamp,InactiveExitTimestamp \
          2>/dev/null || true
      else
        echo "systemctl not found."
      fi
      ;;
    systemv|sysv|sysvinit|initd|init-d|openrc|launchd|bsdrc|bsd-rc|rcd|rc.d)
      echo "Detailed non-systemd status is omitted in safe mode because some tools include raw process details."
      echo "Re-run with --include-raw-details when raw status output is needed."
      ;;
    *)
      echo "Unsupported SERVICE_MANAGER=$SERVICE_MANAGER"
      ;;
  esac
}

raw_service_status() {
  local service_manager_normalized
  service_manager_normalized="$(normalize_name "$SERVICE_MANAGER")"
  case "$service_manager_normalized" in
    systemd)
      systemctl status "$SERVICE_NAME" --no-pager >> "$OUT" 2>&1 || true
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" status >> "$OUT" 2>&1 || true; else "/etc/init.d/${SERVICE_NAME}" status >> "$OUT" 2>&1 || true; fi
      ;;
    openrc)
      rc-service "$SERVICE_NAME" status >> "$OUT" 2>&1 || true
      ;;
    launchd)
      launchctl print "system/${SERVICE_NAME}" >> "$OUT" 2>&1 || true
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v service >/dev/null 2>&1; then
        service "$SERVICE_NAME" status >> "$OUT" 2>&1 || true
      elif command -v rcctl >/dev/null 2>&1; then
        rcctl check "$SERVICE_NAME" >> "$OUT" 2>&1 || true
      elif [[ -x "/usr/local/etc/rc.d/${SERVICE_NAME}" ]]; then
        "/usr/local/etc/rc.d/${SERVICE_NAME}" status >> "$OUT" 2>&1 || true
      else
        "/etc/rc.d/${SERVICE_NAME}" status >> "$OUT" 2>&1 || true
      fi
      ;;
    *)
      echo "Unsupported SERVICE_MANAGER=$SERVICE_MANAGER" >> "$OUT"
      ;;
  esac
}

process_summary() {
  local output
  output="$(ps -eo pid=,ppid=,user=,comm=,etime= 2>/dev/null || ps -axo pid=,ppid=,user=,comm=,etime= 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    echo "Process summary unavailable."
    return
  fi
  printf '%s\n' "$output" |
    awk '{ line=tolower($0); if (line ~ /node|java|tomcat|haproxy|traefik|nginx|httpd|apache/) print }'
}

port_summary() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep ":$APP_PORT" || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | grep ":$APP_PORT" || true
  else
    echo "ss/netstat not found."
  fi
}

http_health_summary() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found."
    return
  fi

  local summary exit_code
  set +e
  summary="$(curl -sS -o /dev/null --max-time 10 -w 'http_code=%{http_code}\ntime_total=%{time_total}\n' "$HEALTH_URL" 2>/dev/null)"
  exit_code=$?
  set -e
  printf '%s\n' "$summary"
  echo "curl_exit=$exit_code"
}

reverse_proxy_summary() {
  case "$(normalize_name "${REVERSE_PROXY:-none}")" in
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
    none|"")
      echo "Reverse proxy disabled."
      ;;
    *)
      echo "Unsupported REVERSE_PROXY=${REVERSE_PROXY:-none}"
      ;;
  esac
}

service_logs_raw() {
  local service_manager_normalized
  service_manager_normalized="$(normalize_name "$SERVICE_MANAGER")"
  if [[ "$service_manager_normalized" == "systemd" ]]; then
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager >> "$OUT" 2>&1 || true
  else
    tail -n 100 "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log" >> "$OUT" 2>&1 || true
  fi
}

list_files_summary() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    echo "Directory not found: $path"
    return
  fi
  if ! find "$path" -maxdepth 1 -type f -printf "%TY-%Tm-%Td %TH:%TM %s %p\n" 2>/dev/null | sort -r | head -20; then
    find "$path" -maxdepth 1 -type f -exec ls -l {} \; 2>/dev/null | head -20 || true
  fi
}

{
  echo "Diagnostics generated $(date -Is)"
  echo "APP_NAME=$APP_NAME"
  echo "SERVICE_NAME=$SERVICE_NAME"
  echo "APP_DIR=$APP_DIR"
  echo "APP_PORT=$APP_PORT"
  echo "HEALTH_URL=$(safe_url "$HEALTH_URL")"
  echo "SERVICE_MANAGER=$SERVICE_MANAGER"
  echo "APP_RUNTIME=${APP_RUNTIME:-node}"
  echo "REVERSE_PROXY=${REVERSE_PROXY:-none}"
  echo "RawDetailsIncluded=$INCLUDE_RAW_DETAILS"
} > "$OUT"

section "System"
uname -srm >> "$OUT" || true
if [[ -r /etc/os-release ]]; then
  grep -E '^(ID|ID_LIKE|VERSION_ID|PRETTY_NAME)=' /etc/os-release >> "$OUT" 2>/dev/null || true
fi

section "Service Summary"
service_status_summary >> "$OUT"

section "Process Summary"
process_summary >> "$OUT"

section "Port"
port_summary >> "$OUT"

section "HTTP Health Summary"
http_health_summary >> "$OUT"

section "Reverse Proxy"
reverse_proxy_summary

section "Health History"
if [[ -f "$HEALTHCHECK_STATE_FILE" ]]; then
  echo "StateFile=$HEALTHCHECK_STATE_FILE" >> "$OUT"
  if ! grep -E '^(CONSECUTIVE_FAILURES|LAST_CHECK_EPOCH|LAST_SUCCESS_EPOCH|LAST_FAILURE_EPOCH|LAST_RESTART_EPOCH)=' "$HEALTHCHECK_STATE_FILE" >> "$OUT" 2>/dev/null; then
    echo "Healthcheck state exists but could not be read. Run diagnostics with sudo or check file permissions." >> "$OUT"
  fi
else
  echo "No healthcheck.state file found at $HEALTHCHECK_STATE_FILE." >> "$OUT"
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

section "Log Files"
list_files_summary "$LOG_DIR" >> "$OUT"

section "Retention And Backups"
{
  echo "LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS:-30}"
  echo "BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-90}"
  echo "DIAGNOSTIC_RETENTION_DAYS=${DIAGNOSTIC_RETENTION_DAYS:-14}"
  echo "BACKUP_DIR=$BACKUP_DIR"
} >> "$OUT"
list_files_summary "$BACKUP_DIR" >> "$OUT"

if [[ "$INCLUDE_RAW_DETAILS" == "true" ]]; then
  section "Raw Service Status"
  raw_service_status

  section "Raw Processes With Arguments"
  ps aux >> "$OUT" 2>&1 || true

  section "Raw HTTP Health Response"
  curl -i --max-time 10 "$HEALTH_URL" >> "$OUT" 2>&1 || true

  section "Raw Service Log Tail"
  service_logs_raw
else
  section "Raw Details"
  echo "Raw service status, process arguments, HTTP response bodies, and log tails were omitted." >> "$OUT"
  echo "Re-run with --include-raw-details only when the output can be handled as sensitive data." >> "$OUT"
fi

echo "Diagnostics written to: $OUT"
