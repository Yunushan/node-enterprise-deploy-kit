#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
# shellcheck source=scripts/linux/app-package-lifecycle.sh
source "$REPO_ROOT/scripts/linux/app-package-lifecycle.sh"

CONFIG_FILE="${1:?Config path is required.}"
STATE_FILE="${2:?Package transaction state path is required.}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

[[ "${EUID}" -eq 0 ]] || { echo "Run package transaction rollback as root." >&2; exit 1; }
[[ -f "$STATE_FILE" ]] || { echo "Package transaction state was not found." >&2; exit 1; }

schema="$(sed -n '1p' "$STATE_FILE")"
transaction_app_dir="$(sed -n '2p' "$STATE_FILE")"
backup_path="$(sed -n '3p' "$STATE_FILE")"
previous_app_existed="$(sed -n '4p' "$STATE_FILE")"
manager="$(sed -n '5p' "$STATE_FILE")"
transaction_app_name="$(sed -n '6p' "$STATE_FILE")"
service_existed="$(sed -n '7p' "$STATE_FILE")"
service_was_running="$(sed -n '8p' "$STATE_FILE")"
[[ "$schema" == "node-enterprise-deploy-kit/package-transaction/v2" ]] || {
  echo "Unsupported package transaction state schema." >&2
  exit 1
}
[[ "$transaction_app_dir" == /* && "$transaction_app_dir" != "/" ]] || {
  echo "Package transaction state contains an unsafe APP_DIR." >&2
  exit 1
}
[[ "$transaction_app_name" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo "Package transaction state contains an unsafe APP_NAME." >&2
  exit 1
}
case "$manager" in
  systemd|systemv|sysv|sysvinit|initd|init-d|openrc|launchd|bsdrc|bsd-rc|rcd|rc.d) ;;
  *) echo "Package transaction state contains an unsupported service manager." >&2; exit 1 ;;
esac
for boolean_value in "$previous_app_existed" "$service_existed" "$service_was_running"; do
  [[ "$boolean_value" == "true" || "$boolean_value" == "false" ]] || {
    echo "Package transaction state contains an invalid boolean." >&2
    exit 1
  }
done
if [[ "$service_was_running" == "true" && "$service_existed" != "true" ]]; then
  echo "Package transaction state cannot mark a missing service as previously running." >&2
  exit 1
fi
if [[ "$previous_app_existed" == "true" ]]; then
  [[ "$backup_path" == /* && "$backup_path" != "$transaction_app_dir" && "$backup_path" != "$transaction_app_dir"/* ]] || {
    echo "Package transaction state contains an unsafe backup path." >&2
    exit 1
  }
elif [[ -n "$backup_path" ]]; then
  echo "Package transaction state contains an unexpected backup path." >&2
  exit 1
fi

package_rollback_deployment_transaction \
  "$transaction_app_dir" \
  "$backup_path" \
  "$previous_app_existed" \
  "$manager" \
  "$transaction_app_name" \
  "$service_existed" \
  "$service_was_running"

if [[ "$service_existed" == "true" && "$service_was_running" == "true" ]]; then
  bash "$REPO_ROOT/scripts/linux/test-post-deploy-health.sh" "$CONFIG_FILE"
fi
