#!/sbin/openrc-run

name="{{APP_DISPLAY_NAME}}"
description="{{APP_DESCRIPTION}}"
command="{{NODE_BIN}}"
command_args="{{START_SCRIPT}} {{NODE_ARGUMENTS}}"
command_user="{{SERVICE_USER}}:{{SERVICE_GROUP}}"
directory="{{APP_DIR}}"
pidfile="/run/{{APP_NAME}}/{{APP_NAME}}.pid"
command_background="yes"
output_log="{{LOG_DIR}}/stdout.log"
error_log="{{LOG_DIR}}/stderr.log"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --owner "{{SERVICE_USER}}:{{SERVICE_GROUP}}" --mode 0750 "/run/{{APP_NAME}}"
  checkpath --directory --owner "{{SERVICE_USER}}:{{SERVICE_GROUP}}" --mode 0750 "{{LOG_DIR}}"
  checkpath --file --owner "{{SERVICE_USER}}:{{SERVICE_GROUP}}" --mode 0640 "{{LOG_DIR}}/stdout.log"
  checkpath --file --owner "{{SERVICE_USER}}:{{SERVICE_GROUP}}" --mode 0640 "{{LOG_DIR}}/stderr.log"
  if [ -f "{{ENV_FILE}}" ]; then
    set -a
    . "{{ENV_FILE}}"
    set +a
  fi
}
