#!/bin/sh
# Native rc.subr consumes daemon metadata and action variables indirectly.
# shellcheck disable=SC2034
# PROVIDE: {{APP_NAME}}
# REQUIRE: NETWORKING
# KEYWORD: shutdown

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
  ps -p "$PID" -o uid= -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
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
  PID="$(su -m "$SERVICE_USER" -c "bash -c $(quote_shell "cd \"$APP_DIR\" || exit 1; set -a; [ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"; set +a; nohup \"$NODE_BIN\" \"$START_SCRIPT\" $NODE_ARGUMENTS >> \"$LOG_DIR/stdout.log\" 2>> \"$LOG_DIR/stderr.log\" & echo \$!")")" || return 1
  (umask 077; printf '%s\n' "$PID" > "$PID_FILE") || return 1
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

quote_shell() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
node_app_restart() { stop && start; }
kernel="$(uname -s)"
case "$kernel" in
  OpenBSD)
    # rcctl requires native rc.subr daemon metadata and check/start/stop actions.
    daemon="$NODE_BIN"
    daemon_user="$SERVICE_USER"
    daemon_flags="$START_SCRIPT $NODE_ARGUMENTS"
    . /etc/rc.d/rc.subr
    rc_start() { start; }
    rc_stop() { stop; }
    rc_check() { is_running; }
    rc_reload=NO
    rc_bg=NO
    rc_usercheck=NO
    action="${1:-}"
    [ "$action" != "status" ] || action=check
    rc_cmd "$action"
    ;;
  FreeBSD|NetBSD)
    . /etc/rc.subr
    name="$(printf '%s' "$APP_NAME" | tr '.-' '__')"
    case "$name" in [A-Za-z_]*) ;; *) name="node_$name" ;; esac
    case "$kernel" in FreeBSD) rcvar="${name}_enable" ;; NetBSD) rcvar="$name" ;; esac
    start_cmd=start
    stop_cmd=stop
    status_cmd=status
    extra_commands="status"
    restart_cmd=node_app_restart
    load_rc_config "$name"
    run_rc_command "${1:-}"
    ;;
  *)
    echo "Unsupported BSD kernel: $kernel" >&2
    exit 2
    ;;
esac
