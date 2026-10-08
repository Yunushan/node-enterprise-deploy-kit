#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=scripts/linux/app-package-lifecycle.sh
source "$SCRIPT_DIR/app-package-lifecycle.sh"
operation="${1:?Transaction operation required.}"
CONFIG_FILE="${2:?Deployment config required.}"
NODE_DEPLOY_TRANSACTION_DIR="${3:?Journal directory required.}"
export NODE_DEPLOY_TRANSACTION_DIR
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
[[ "$EUID" -eq 0 ]] || { echo "Managed deployment transaction requires root." >&2; exit 1; }
[[ "$APP_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Unsafe APP_NAME." >&2; exit 1; }
manager="$(normalize_name "${SERVICE_MANAGER:-$(default_service_manager "$(detect_platform_family)")}")"
mutation_locks_acquire
trap mutation_locks_release EXIT
service_name="$APP_NAME"
case "$(normalize_name "${APP_RUNTIME:-node}")" in tomcat|apache-tomcat) service_name="${TOMCAT_SERVICE:-tomcat}" ;; esac

managed_manager_identity() {
  case "$(normalize_name "$1")" in
    systemv|sysv|sysvinit|initd|init-d) printf 'systemv\n' ;;
    bsdrc|bsd-rc|rcd|rc.d) printf 'bsdrc\n' ;;
    *) normalize_name "$1" ;;
  esac
}
managed_runtime_identity() {
  case "$(normalize_name "$1")" in apache-tomcat|tomcat) printf 'tomcat\n' ;; *) normalize_name "$1" ;; esac
}
managed_proxy_identity() {
  case "$(normalize_name "$1")" in apache|httpd) printf 'apache\n' ;; none|'') printf 'none\n' ;; *) normalize_name "$1" ;; esac
}
assert_managed_config_update_identity() {
  local previous="/etc/node-enterprise-deploy-kit/$APP_NAME.env" old_identity new_identity old_transaction_root
  transaction_assert_safe_path "$previous" || return 1
  [[ -f "$previous" ]] || return 0
  hardening_assert_control_file "$previous" || return 1
  old_transaction_root="$(
    unset DEPLOYMENT_TRANSACTION_ROOT
    # shellcheck disable=SC1090
    source "$previous"
    printf '%s\n' "${DEPLOYMENT_TRANSACTION_ROOT:-/var/lib/node-enterprise-deploy-kit/deployment-transactions}"
  )" || return 1
  # A root-location update must not hide unfinished evidence in the previously
  # installed protected monitor configuration's persistent namespace.
  hardening_assert_no_pending_transactions "$DEPLOYMENT_LOCK_PATH" "" "" "$old_transaction_root" || return 1
  old_identity="$(
    unset SERVICE_MANAGER APP_RUNTIME REVERSE_PROXY TOMCAT_SERVICE APP_NAME
    # Previous protected configuration is trusted input, evaluated in isolation
    # so its private values cannot replace the incoming deployment configuration.
    # shellcheck disable=SC1090
    source "$previous"
    managed_manager_identity "${SERVICE_MANAGER:-$(default_service_manager "$(detect_platform_family)")}"
    managed_runtime_identity "${APP_RUNTIME:-node}"
    managed_proxy_identity "${REVERSE_PROXY:-none}"
    case "$(managed_runtime_identity "${APP_RUNTIME:-node}")" in tomcat) printf '%s\n' "${TOMCAT_SERVICE:-tomcat}" ;; *) printf '%s\n' "${APP_NAME:-}" ;; esac
  )" || return 1
  new_identity="$(
    managed_manager_identity "$manager"
    managed_runtime_identity "${APP_RUNTIME:-node}"
    managed_proxy_identity "${REVERSE_PROXY:-none}"
    printf '%s\n' "$service_name"
  )"
  if [[ "$old_identity" != "$new_identity" ]]; then
    echo 'In-place service-manager, runtime, proxy-type, or Tomcat-service migration is not supported by the deployment update transaction.' >&2
    echo 'Use the previous protected configuration to stop and unregister its service/monitor and remove its old proxy routes, then deploy the new selection.' >&2
    return 1
  fi
}

record_service_control() {
  local name="$1" output="$2" control_manager="${3:-$manager}" existed=false running=false enabled="" active_state disabled
  if package_app_service_exists "$control_manager" "$name"; then existed=true; fi
  if package_app_service_is_running "$control_manager" "$name"; then running=true; fi
  if [[ "$control_manager" == systemd && "$existed" == true ]]; then
    active_state="$(systemctl show "$name" --property=ActiveState --value 2>/dev/null || true)"
    case "$active_state" in activating|reloading|active) running=true ;; esac
    enabled="$(systemctl is-enabled "$name" 2>/dev/null || true)"
    case "$enabled" in enabled|enabled-runtime|disabled|static|indirect|masked|masked-runtime|generated|alias|linked|linked-runtime) ;;
      *) echo "Could not determine previous service enablement: $name" >&2; return 1 ;;
    esac
  elif [[ "$control_manager" == launchd ]]; then
    disabled="$(launchctl print-disabled system)" || return 1
    if printf '%s\n' "$disabled" | grep -F "\"$name\"" | grep -Eq '=>[[:space:]]*true'; then enabled=disabled; else enabled=enabled; fi
  fi
  if [[ "$control_manager" == systemd ]]; then
    local unit="$name"
    case "$unit" in *.service|*.timer) ;; *) unit="$unit.service" ;; esac
    transaction_record_registration /etc/systemd/system systemd "$unit"
    transaction_record_registration /run/systemd/system systemd "$unit"
  fi
  printf '%s\n' "$name" "$existed" "$running" "$enabled" "$control_manager" > "$output"
}

restore_service_control() {
  local input="$1" name existed running enabled control_manager
  [[ -f "$input" ]] || return 0
  name="$(sed -n '1p' "$input")"; existed="$(sed -n '2p' "$input")"
  running="$(sed -n '3p' "$input")"; enabled="$(sed -n '4p' "$input")"
  control_manager="$(sed -n '5p' "$input")"; control_manager="${control_manager:-$manager}"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ && "$existed" =~ ^(true|false)$ && "$running" =~ ^(true|false)$ ]] || return 1
  package_stop_app_service "$control_manager" "$name"
  if [[ "$existed" == false ]]; then package_remove_new_service_after_failure "$control_manager" "$name"; return; fi
  if [[ "$control_manager" == systemd ]]; then
    case "$enabled" in
      enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect|generated|alias|linked|linked-runtime) ;;
      *) return 1 ;;
    esac
  elif [[ "$control_manager" == launchd ]]; then
    case "$enabled" in enabled) launchctl enable "system/$name" ;; disabled) launchctl disable "system/$name" ;; *) return 1 ;; esac
  fi
  if [[ "$running" == true ]]; then
    if [[ "$control_manager" == systemd && ( "$enabled" == masked || "$enabled" == masked-runtime ) ]]; then systemctl unmask "$name"; systemctl unmask --runtime "$name"; fi
    # Consumed by the sourced package lifecycle recovery function.
    # shellcheck disable=SC2034
    PACKAGE_APP_SERVICE_WAS_RUNNING=true
    package_restart_app_service_after_failure "$control_manager" "$name"
  fi
  if [[ "$control_manager" == systemd ]]; then
    case "$enabled" in masked|masked-runtime) transaction_restore_registration; systemctl daemon-reload ;; esac
  fi
}

restore_health_control() {
  restore_service_control "$NODE_DEPLOY_TRANSACTION_DIR/health.control"
  restore_service_control "$NODE_DEPLOY_TRANSACTION_DIR/health-worker.control"
  transaction_restore_root_crontab
}

wait_for_previous_monitor_invokers() {
  local timeout="${HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS:-30}" deadline snapshot pids
  [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -le 300 ]] || { echo 'HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS must be an integer from 0 through 300.' >&2; return 1; }
  deadline=$(( $(date +%s) + timeout ))
  snapshot="$NODE_DEPLOY_TRANSACTION_DIR/monitor.processes"
  while :; do
    ps -axww -o pid= -o uid= -o args= > "$snapshot" || return 1
    pids="$(awk -v script="/usr/local/sbin/$APP_NAME-healthcheck.sh" -v config="/etc/node-enterprise-deploy-kit/$APP_NAME.env" -v self="$$" \
      '$2 == 0 && $1 != self && index($0, script) && index($0, config) {print $1}' "$snapshot")"
    [[ -n "$pids" ]] || { rm "$snapshot"; return 0; }
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      echo "An existing privileged health monitor has not exited; application files remain untouched. PIDs: $pids" >&2
      return 1
    fi
    sleep 1
  done
}

quiesce_health_control() {
  local current stripped
  if [[ "$manager" == systemd ]]; then
    if [[ "$(sed -n '2p' "$NODE_DEPLOY_TRANSACTION_DIR/health.control")" == true ]]; then systemctl stop "$APP_NAME-healthcheck.timer"; fi
    if [[ "$(sed -n '2p' "$NODE_DEPLOY_TRANSACTION_DIR/health-worker.control")" == true ]]; then systemctl stop "$APP_NAME-healthcheck.service"; fi
  elif [[ "$manager" == launchd && "$(sed -n '3p' "$NODE_DEPLOY_TRANSACTION_DIR/health.control")" == true ]]; then
    launchctl bootout "system/$APP_NAME-healthcheck"
  fi
  if [[ -f "$NODE_DEPLOY_TRANSACTION_DIR/cron.app" ]]; then
    current="$(mktemp "$NODE_DEPLOY_TRANSACTION_DIR/cron.quiesce.current.XXXXXX")"
    stripped="$(mktemp "$NODE_DEPLOY_TRANSACTION_DIR/cron.quiesce.stripped.XXXXXX")"
    crontab -l > "$current" 2>/dev/null || : > "$current"
    awk -v start="# node-enterprise-deploy-kit:$APP_NAME:healthcheck:start" -v end="# node-enterprise-deploy-kit:$APP_NAME:healthcheck:end" \
      '$0 == start {inside=1; next} $0 == end {inside=0; next} !inside {print}' "$current" > "$stripped"
    if ! cmp -s "$current" "$stripped"; then crontab "$stripped"; fi
    rm "$current" "$stripped"
  fi
  wait_for_previous_monitor_invokers
  printf 'complete\n' > "$NODE_DEPLOY_TRANSACTION_DIR/health.quiesced"
}

case "$operation" in
  begin)
    deployment_assert_no_pending_transactions
    case "$NODE_DEPLOY_TRANSACTION_DIR" in "$DEPLOYMENT_TRANSACTION_PREFIX".managed-transaction.*) ;;
      *) echo 'New managed journals must use the protected persistent application transaction namespace.' >&2; exit 1 ;;
    esac
    assert_managed_config_update_identity
    transaction_begin "$NODE_DEPLOY_TRANSACTION_DIR"
    if [[ -n "${4:-}" ]]; then
      case "$4" in "$DEPLOYMENT_TRANSACTION_PREFIX".package-transaction.*.state) ;; *) echo 'Package state must use the protected persistent application transaction namespace.' >&2; exit 1 ;; esac
      transaction_assert_safe_path "$4"
      (umask 077; printf '%s\n' "$4" > "$NODE_DEPLOY_TRANSACTION_DIR/package-state-path")
    fi
    record_service_control "$service_name" "$NODE_DEPLOY_TRANSACTION_DIR/app.control"
    case "$manager" in
      systemv|sysv|sysvinit|initd|init-d) transaction_record_registration /etc sysv "$service_name" ;;
      openrc) transaction_record_registration /etc openrc "$service_name" ;;
    esac
    if [[ "$manager" == systemd ]]; then
      record_service_control "$APP_NAME-healthcheck.timer" "$NODE_DEPLOY_TRANSACTION_DIR/health.control"
      record_service_control "$APP_NAME-healthcheck.service" "$NODE_DEPLOY_TRANSACTION_DIR/health-worker.control"
    elif [[ "$manager" == launchd ]]; then
      record_service_control "$APP_NAME-healthcheck" "$NODE_DEPLOY_TRANSACTION_DIR/health.control"
    fi
    if command -v crontab >/dev/null 2>&1; then
      cron_inspection="$NODE_DEPLOY_TRANSACTION_DIR/cron.inspection"
      crontab -l > "$cron_inspection" 2>/dev/null || : > "$cron_inspection"
      if grep -Fxq "# node-enterprise-deploy-kit:$APP_NAME:healthcheck:start" "$cron_inspection"; then transaction_record_root_crontab; fi
      rm "$cron_inspection"
    fi
    old_config="/etc/node-enterprise-deploy-kit/$APP_NAME.env"
    transaction_assert_safe_path "$old_config"
    if [[ -f "$old_config" ]]; then cp "$old_config" "$NODE_DEPLOY_TRANSACTION_DIR/rollback.config"; else cp "$CONFIG_FILE" "$NODE_DEPLOY_TRANSACTION_DIR/rollback.config"; fi
    chmod 0600 "$NODE_DEPLOY_TRANSACTION_DIR/rollback.config"
    proxy="$(normalize_name "${REVERSE_PROXY:-none}")"; proxy_name=""
    case "$proxy" in
      nginx) proxy_name="${NGINX_SERVICE:-nginx}" ;;
      apache|httpd) proxy_name="${APACHE_SERVICE:-$(if [[ "$(detect_platform_family)" == rhel ]]; then printf httpd; else printf apache2; fi)}" ;;
      haproxy) proxy_name="${HAPROXY_SERVICE:-haproxy}" ;;
      traefik) proxy_name="${TRAEFIK_SERVICE:-traefik}" ;;
    esac
    if [[ -n "$proxy_name" ]]; then
      proxy_manager="$manager"
      if service_exists_systemd "$proxy_name"; then proxy_manager=systemd; fi
      record_service_control "$proxy_name" "$NODE_DEPLOY_TRANSACTION_DIR/proxy.control" "$proxy_manager"
    fi
    printf 'quiesce-v1\n' > "$NODE_DEPLOY_TRANSACTION_DIR/monitor-protocol"
    ;;
  quiesce)
    transaction_assert_journal
    quiesce_health_control
    package_stop_app_service "$manager" "$service_name"
    ;;
  quiesce-health)
    transaction_assert_journal
    quiesce_health_control
    ;;
  resume-health)
    transaction_assert_journal
    restore_health_control
    ;;
  restore)
    transaction_assert_journal
    if [[ -f "$NODE_DEPLOY_TRANSACTION_DIR/monitor-protocol" && ! -f "$NODE_DEPLOY_TRANSACTION_DIR/health.quiesced" ]]; then
      # Quiescing failed before app mutation; an old cron invoker may still be
      # running. Resume only the suspended scheduler, leaving the app untouched.
      restore_health_control
      exit 0
    fi
    package_stop_app_service "$manager" "$service_name"
    if [[ "$manager" == systemd ]]; then systemctl stop "$APP_NAME-healthcheck.timer" 2>/dev/null || true; fi
    if [[ "$manager" == systemd && -f "$NODE_DEPLOY_TRANSACTION_DIR/health-worker.control" && "$(sed -n '2p' "$NODE_DEPLOY_TRANSACTION_DIR/health-worker.control")" == true ]]; then systemctl stop "$APP_NAME-healthcheck.service"; fi
    if [[ "$manager" == launchd ]]; then launchctl bootout "system/$APP_NAME-healthcheck" >/dev/null 2>&1 || true; fi
    transaction_restore_files
    if [[ "$manager" == systemd ]]; then systemctl daemon-reload; fi
    restore_service_control "$NODE_DEPLOY_TRANSACTION_DIR/app.control"
    restore_health_control
    restore_service_control "$NODE_DEPLOY_TRANSACTION_DIR/proxy.control"
    if [[ "$(sed -n '3p' "$NODE_DEPLOY_TRANSACTION_DIR/app.control")" == true ]]; then
      bash "$SCRIPT_DIR/test-post-deploy-health.sh" "$NODE_DEPLOY_TRANSACTION_DIR/rollback.config"
    fi
    ;;
  finish) transaction_finish ;;
  *) echo "Unknown managed deployment transaction operation." >&2; exit 2 ;;
esac
