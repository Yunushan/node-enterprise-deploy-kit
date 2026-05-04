#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-$REPO_ROOT/config/linux/app.env}"
CONFIG_FILE="$(resolve_config_path "$REPO_ROOT" "$CONFIG_FILE")"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE. Copy config/linux/app.env.example first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"
PLATFORM_FAMILY="$(detect_platform_family)"
APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"
SERVICE_MANAGER_NORMALIZED="$(normalize_name "${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}")"
REVERSE_PROXY_NORMALIZED="$(normalize_name "${REVERSE_PROXY:-none}")"

SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
ALLOW_PORT_IN_USE="${ALLOW_PORT_IN_USE:-false}"
SKIP_REVERSE_PROXY="${SKIP_REVERSE_PROXY:-false}"
SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-false}"

if ! is_true "$SKIP_PREFLIGHT"; then
  preflight_args=("$CONFIG_FILE")
  if is_true "$ALLOW_PORT_IN_USE"; then preflight_args+=(--allow-port-in-use); fi
  if is_true "$SKIP_REVERSE_PROXY"; then preflight_args+=(--skip-reverse-proxy); fi
  if is_true "$SKIP_HEALTH_CHECK"; then preflight_args+=(--skip-health-check); fi
  bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "${preflight_args[@]}"
fi

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    bash "$@"
  else
    sudo bash "$@"
  fi
}

case "$APP_RUNTIME_NORMALIZED" in
  node)
    run_root "$REPO_ROOT/scripts/linux/install-node-service.sh" "$CONFIG_FILE"
    ;;
  tomcat|apache-tomcat)
    run_root "$REPO_ROOT/scripts/linux/install-tomcat-app.sh" "$CONFIG_FILE"
    ;;
  *)
    echo "Unsupported APP_RUNTIME: ${APP_RUNTIME:-node}. Use node or tomcat." >&2
    exit 1
    ;;
esac

if ! is_true "$SKIP_REVERSE_PROXY"; then
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx)
      run_root "$REPO_ROOT/scripts/linux/install-nginx-reverse-proxy.sh" "$CONFIG_FILE"
      ;;
    apache|httpd)
      run_root "$REPO_ROOT/scripts/linux/install-apache-reverse-proxy.sh" "$CONFIG_FILE"
      ;;
    haproxy)
      run_root "$REPO_ROOT/scripts/linux/install-haproxy-reverse-proxy.sh" "$CONFIG_FILE"
      ;;
    traefik)
      run_root "$REPO_ROOT/scripts/linux/install-traefik-reverse-proxy.sh" "$CONFIG_FILE"
      ;;
    none|"")
      ;;
    *)
      echo "Unsupported REVERSE_PROXY: $REVERSE_PROXY. Use nginx, apache, haproxy, traefik, or none." >&2
      exit 1
      ;;
  esac
fi

if is_true "$SKIP_HEALTH_CHECK"; then
  echo "Skipping healthcheck timer because SKIP_HEALTH_CHECK=true."
elif [[ "$SERVICE_MANAGER_NORMALIZED" == "systemd" ]]; then
  run_root "$REPO_ROOT/scripts/linux/install-healthcheck-timer.sh" "$CONFIG_FILE"
else
  echo "Skipping systemd healthcheck timer for SERVICE_MANAGER=${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}."
fi

echo "Deployment finished for ${APP_NAME}."
