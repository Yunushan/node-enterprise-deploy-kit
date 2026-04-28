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

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

prepare_runtime() {
  mkdir -p "$PID_DIR" "$LOG_DIR"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$PID_DIR" "$LOG_DIR" 2>/dev/null || true
  chmod 0750 "$PID_DIR" "$LOG_DIR" 2>/dev/null || true
  touch "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log" 2>/dev/null || true
}

start() {
  if is_running; then
    echo "$APP_DISPLAY_NAME is already running."
    return 0
  fi
  prepare_runtime
  echo "Starting $APP_DISPLAY_NAME..."
  if command -v start-stop-daemon >/dev/null 2>&1; then
    start-stop-daemon --start --background --make-pidfile --pidfile "$PID_FILE" \
      --chuid "$SERVICE_USER:$SERVICE_GROUP" --chdir "$APP_DIR" --startas /bin/sh -- \
      -c "set -a; [ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"; set +a; exec \"$NODE_BIN\" \"$START_SCRIPT\" $NODE_ARGUMENTS >> \"$LOG_DIR/stdout.log\" 2>> \"$LOG_DIR/stderr.log\""
  else
    su -s /bin/sh "$SERVICE_USER" -c "cd \"$APP_DIR\" && set -a; [ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"; set +a; nohup \"$NODE_BIN\" \"$START_SCRIPT\" $NODE_ARGUMENTS >> \"$LOG_DIR/stdout.log\" 2>> \"$LOG_DIR/stderr.log\" & echo \$! > \"$PID_FILE\""
  fi
}

stop() {
  if ! is_running; then
    echo "$APP_DISPLAY_NAME is not running."
    rm -f "$PID_FILE"
    return 0
  fi
  echo "Stopping $APP_DISPLAY_NAME..."
  PID="$(cat "$PID_FILE")"
  kill "$PID" 2>/dev/null || true
  i=0
  while kill -0 "$PID" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
      kill -9 "$PID" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  rm -f "$PID_FILE"
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
    stop
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
