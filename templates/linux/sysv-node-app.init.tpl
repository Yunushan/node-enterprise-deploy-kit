#!/bin/sh
### BEGIN INIT INFO
# Provides:          {{APP_NAME}}
# Required-Start:    $remote_fs $syslog $network
# Required-Stop:     $remote_fs $syslog $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: {{APP_DISPLAY_NAME}}
# Description:       {{APP_DESCRIPTION}}
### END INIT INFO

APP_NAME="{{APP_NAME}}"
APP_DISPLAY_NAME="{{APP_DISPLAY_NAME}}"
SERVICE_USER="{{SERVICE_USER}}"
SERVICE_GROUP="{{SERVICE_GROUP}}"
APP_DIR="{{APP_DIR}}"
ENV_FILE="{{ENV_FILE}}"
NODE_BIN="{{NODE_BIN}}"
START_SCRIPT="{{START_SCRIPT}}"
NODE_ARGUMENTS="{{NODE_ARGUMENTS}}"
LOG_DIR="{{LOG_DIR}}"
PID_DIR="/var/run/${APP_NAME}"
PID_FILE="${PID_DIR}/${APP_NAME}.pid"
PID_IDENTITY_FILE="${PID_FILE}.identity"

trusted_control_path() {
  path="$1"
  [ ! -L "$path" ] && [ -e "$path" ] || return 1
  metadata="$(stat -c '%u %a' "$path" 2>/dev/null || stat -f '%u %Lp' "$path" 2>/dev/null)" || return 1
  owner="${metadata%% *}"
  mode="${metadata#* }"
  [ "$owner" = 0 ] || return 1
  case "$mode" in *[2367][0-7]|*[0-7][2367]) return 1 ;; esac
}

pid_directory_trusted() {
  [ -d "$PID_DIR" ] && trusted_control_path "$PID_DIR"
}

read_pid() {
  pid_directory_trusted && [ -f "$PID_FILE" ] && trusted_control_path "$PID_FILE" || return 1
  PID="$(cat "$PID_FILE")"
  case "$PID" in ''|*[!0-9]*) return 1 ;; esac
  [ "$PID" -gt 1 ] 2>/dev/null || return 1
}

process_identity() {
  process_uid="$(ps -p "$PID" -o uid= 2>/dev/null | tr -d '[:space:]')"
  case "$process_uid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$PID/stat" ]; then
    # Linux field 22 is stable across exec/title changes and detects PID reuse.
    process_stat="$(cat "/proc/$PID/stat")" || return 1
    process_ticks="$(printf '%s\n' "${process_stat##*) }" | awk '{print $20}')"
    case "$process_ticks" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s ticks=%s\n' "$process_uid" "$process_ticks"
  else
    ps -p "$PID" -o uid= -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  fi
}

is_running() {
  read_pid && [ -f "$PID_IDENTITY_FILE" ] && trusted_control_path "$PID_IDENTITY_FILE" || return 1
  identity="$(process_identity)"
  [ -n "$identity" ] && [ "$identity" = "$(cat "$PID_IDENTITY_FILE")" ] && kill -0 "$PID" 2>/dev/null
}

prepare_runtime() {
  [ ! -L "$PID_DIR" ] || return 1
  if [ -e "$PID_DIR" ] && ! pid_directory_trusted; then
    echo "Refusing untrusted PID directory: $PID_DIR. Stop the legacy service and remove its old PID directory before upgrading." >&2
    return 1
  fi
  (umask 077; mkdir -p "$PID_DIR") || return 1
  chown "root:$(id -gn root)" "$PID_DIR" || return 1
  chmod 0700 "$PID_DIR" || return 1
  pid_directory_trusted
}

record_pid_identity() {
  expected_uid="$(id -u "$SERVICE_USER")" || return 1
  attempts=0
  while [ "$attempts" -lt 10 ]; do
    if read_pid; then
      actual_uid="$(ps -p "$PID" -o uid= 2>/dev/null | tr -d '[:space:]')"
      if [ "$actual_uid" = "$expected_uid" ]; then
        identity="$(process_identity)"
        [ -n "$identity" ] || return 1
        (umask 077; printf '%s\n' "$identity" > "$PID_IDENTITY_FILE") || return 1
        chown "root:$(id -gn root)" "$PID_FILE" "$PID_IDENTITY_FILE" || return 1
        chmod 0600 "$PID_FILE" "$PID_IDENTITY_FILE" || return 1
        return 0
      fi
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  echo "Service did not establish a trusted Node process identity." >&2
  return 1
}

start() {
  if is_running; then
    echo "$APP_DISPLAY_NAME is already running."
    return 0
  fi
  prepare_runtime || return 1
  rm -f "$PID_FILE" "$PID_IDENTITY_FILE"
  echo "Starting $APP_DISPLAY_NAME..."
  if command -v start-stop-daemon >/dev/null 2>&1; then
    start-stop-daemon --start --background --make-pidfile --pidfile "$PID_FILE" \
      --chuid "$SERVICE_USER:$SERVICE_GROUP" --chdir "$APP_DIR" --startas /bin/sh -- \
      -c "set -a; [ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"; set +a; exec \"$NODE_BIN\" \"$START_SCRIPT\" $NODE_ARGUMENTS >> \"$LOG_DIR/stdout.log\" 2>> \"$LOG_DIR/stderr.log\"" || return 1
  else
    PID="$(su -s /bin/sh "$SERVICE_USER" -c "cd \"$APP_DIR\" || exit 1; set -a; [ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"; set +a; nohup \"$NODE_BIN\" \"$START_SCRIPT\" $NODE_ARGUMENTS >> \"$LOG_DIR/stdout.log\" 2>> \"$LOG_DIR/stderr.log\" & echo \$!")" || return 1
    (umask 077; printf '%s\n' "$PID" > "$PID_FILE") || return 1
  fi
  record_pid_identity
}

stop() {
  [ ! -e "$PID_DIR" ] && return 0
  pid_directory_trusted || { echo "Refusing to signal a process from an untrusted PID directory." >&2; return 1; }
  if ! is_running; then
    echo "$APP_DISPLAY_NAME is not running."
    rm -f "$PID_FILE" "$PID_IDENTITY_FILE"
    return 0
  fi
  echo "Stopping $APP_DISPLAY_NAME..."
  kill "$PID" 2>/dev/null || true
  i=0
  while is_running; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      is_running && kill -9 "$PID" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  rm -f "$PID_FILE" "$PID_IDENTITY_FILE"
}

status() {
  if is_running; then
    echo "$APP_DISPLAY_NAME is running with PID $(cat "$PID_FILE")."
  else
    echo "$APP_DISPLAY_NAME is stopped."
    return 3
  fi
}

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop || exit 1
    start
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 2
    ;;
esac
