#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-$REPO_ROOT/config/linux/app.env}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
PLATFORM_FAMILY="$(detect_platform_family)"
APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"

SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
ALLOW_PORT_IN_USE="${ALLOW_PORT_IN_USE:-false}"
SKIP_PACKAGE_IMPORT="${SKIP_PACKAGE_IMPORT:-false}"
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

if ! is_true "$SKIP_PACKAGE_IMPORT" && [[ -n "${PACKAGE_PATH:-}" ]]; then
  if [[ "$APP_RUNTIME_NORMALIZED" != "node" ]]; then
    echo "PACKAGE_PATH imports are for APP_RUNTIME=node. Use TOMCAT_WAR_FILE for Tomcat deployments." >&2
    exit 1
  fi
  run_root "$REPO_ROOT/scripts/linux/import-app-package.sh" "$CONFIG_FILE"
fi

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
  bash "$REPO_ROOT/scripts/linux/install-reverse-proxy.sh" "$CONFIG_FILE"
fi

if is_true "$SKIP_HEALTH_CHECK"; then
  echo "Skipping healthcheck scheduler because SKIP_HEALTH_CHECK=true."
else
  run_root "$REPO_ROOT/scripts/linux/install-healthcheck-scheduler.sh" "$CONFIG_FILE"
fi

echo "Deployment finished for ${APP_NAME}."
