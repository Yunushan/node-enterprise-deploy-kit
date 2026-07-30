#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
CONFIG_FILE="${1:-$REPO_ROOT/config/linux/app.env}"
PACKAGE_PATH_OVERRIDE="${2:-}"
PACKAGE_EXPECTED_SHA256_OVERRIDE="${3:-}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
if [[ -n "$PACKAGE_PATH_OVERRIDE" ]]; then PACKAGE_PATH="$PACKAGE_PATH_OVERRIDE"; fi
if [[ -n "$PACKAGE_EXPECTED_SHA256_OVERRIDE" ]]; then PACKAGE_EXPECTED_SHA256="$PACKAGE_EXPECTED_SHA256_OVERRIDE"; fi
APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    bash "$@"
  else
    sudo bash "$@"
  fi
}

run_privileged() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# shellcheck source=scripts/linux/deployment-lock.sh
source "$REPO_ROOT/scripts/linux/deployment-lock.sh"
deployment_lock_acquire "$APP_NAME"
trap deployment_lock_release EXIT
PACKAGE_TRANSACTION_STATE_PATH="${DEPLOYMENT_LOCK_PATH}.package-transaction.$$.state"

deployment_error_handler() {
  local deployment_exit=$?
  local rollback_failed=false
  trap - ERR
  if run_privileged test -f "$PACKAGE_TRANSACTION_STATE_PATH"; then
    if ! run_root "$REPO_ROOT/scripts/linux/rollback-app-package-transaction.sh" "$CONFIG_FILE" "$PACKAGE_TRANSACTION_STATE_PATH"; then
      echo "CRITICAL: Deployment failed and automatic package rollback also failed. The service remains stopped when APP_DIR recovery was unsafe." >&2
      echo "Recovery state preserved at: $PACKAGE_TRANSACTION_STATE_PATH" >&2
      rollback_failed=true
    fi
  fi
  if [[ "$rollback_failed" != "true" ]]; then
    run_privileged rm -f "$PACKAGE_TRANSACTION_STATE_PATH" ||
      echo "WARNING: Could not remove package transaction state: $PACKAGE_TRANSACTION_STATE_PATH" >&2
  fi
  exit "$deployment_exit"
}
trap deployment_error_handler ERR

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
  if [[ -n "${PACKAGE_PATH_OVERRIDE:-}" ]]; then preflight_args+=(--package-path "$PACKAGE_PATH_OVERRIDE"); fi
  if [[ -n "${PACKAGE_EXPECTED_SHA256_OVERRIDE:-}" ]]; then preflight_args+=(--package-expected-sha256 "$PACKAGE_EXPECTED_SHA256_OVERRIDE"); fi
  bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "${preflight_args[@]}"
fi

if ! is_true "$SKIP_PACKAGE_IMPORT" && [[ -n "${PACKAGE_PATH:-}" ]]; then
  if [[ "$APP_RUNTIME_NORMALIZED" != "node" ]]; then
    echo "PACKAGE_PATH imports are for APP_RUNTIME=node. Use TOMCAT_WAR_FILE for Tomcat deployments." >&2
    exit 1
  fi
  run_root "$REPO_ROOT/scripts/linux/import-app-package.sh" "$CONFIG_FILE" "${PACKAGE_PATH:-}" "${PACKAGE_EXPECTED_SHA256:-}" "$PACKAGE_TRANSACTION_STATE_PATH"
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

run_privileged rm -f "$PACKAGE_TRANSACTION_STATE_PATH"
trap - ERR
echo "Deployment finished for ${APP_NAME}."
