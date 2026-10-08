#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
# shellcheck source=scripts/linux/app-package-lifecycle.sh
source "$REPO_ROOT/scripts/linux/app-package-lifecycle.sh"
fixture="$(mktemp -d "$REPO_ROOT/.tmp/package-wal.XXXXXX")"
cleanup() {
  [[ "$fixture" == "$REPO_ROOT/.tmp/package-wal."* && -d "$fixture" && ! -L "$fixture" ]] || exit 1
  rm -rf -- "$fixture"
}
trap cleanup EXIT
app="$fixture/app"; source_root="$fixture/source"; backups="$fixture/backups"
mkdir -p "$app" "$source_root"
printf '%s\n' v1 > "$app/version"
printf '%s\n' v2 > "$source_root/version"
manifest_ok() { :; }
manifest_fail() { return 1; }
prepared_record() {
  [[ "$(cat "$app/version")" == v1 && "$PACKAGE_APP_PREVIOUS_EXISTED" == true && ! -e "$PACKAGE_APP_BACKUP_PATH" ]]
  printf '%s\n' "$PACKAGE_APP_BACKUP_PATH" > "$fixture/prepared-backup"
}
prepared_fail() { return 1; }
package_app_service_is_running() { return 1; }
package_remove_new_service_after_failure() { :; }
transaction_restore_files() { :; }

# A refused write-ahead record must leave the original app untouched.
if package_replace_app_directory "$source_root" "$app" "$backups" manifest_ok prepared_fail; then exit 1; fi
[[ "$(cat "$app/version")" == v1 && ! -e "$PACKAGE_APP_BACKUP_PATH" ]]
package_rollback_deployment_transaction "$app" "$PACKAGE_APP_BACKUP_PATH" true none package-wal false false prepared
[[ "$(cat "$app/version")" == v1 ]]

# The record must name the exact old directory before it moves, including when
# a crash follows the move while the record is still in its prepared phase.
package_replace_app_directory "$source_root" "$app" "$backups" manifest_ok prepared_record
[[ "$(cat "$fixture/prepared-backup")" == "$PACKAGE_APP_BACKUP_PATH" && "$(cat "$PACKAGE_APP_BACKUP_PATH/version")" == v1 && "$(cat "$app/version")" == v2 ]]
package_rollback_deployment_transaction "$app" "$PACKAGE_APP_BACKUP_PATH" true none package-wal false false prepared
[[ "$(cat "$app/version")" == v1 ]]

# If the importer's own failure recovery already consumed the backup, the
# parent's prepared-state rollback must preserve the restored app.
if package_replace_app_directory "$source_root" "$app" "$backups" manifest_fail prepared_record; then exit 1; fi
[[ "$(cat "$app/version")" == v1 && ! -e "$PACKAGE_APP_BACKUP_PATH" ]]
package_rollback_deployment_transaction "$app" "$PACKAGE_APP_BACKUP_PATH" true none package-wal false false prepared
[[ "$(cat "$app/version")" == v1 ]]

# A first installation has no previous directory; remove its partial app.
fresh="$fixture/fresh"
prepared_fresh() { [[ "$PACKAGE_APP_PREVIOUS_EXISTED" == false && -z "$PACKAGE_APP_BACKUP_PATH" && ! -e "$fresh" ]]; }
package_replace_app_directory "$source_root" "$fresh" "$backups" manifest_ok prepared_fresh
package_rollback_deployment_transaction "$fresh" '' false none package-wal false false prepared
[[ ! -e "$fresh" ]]
echo 'Package write-ahead ordering, pre-move refusal, prepared recovery, and fresh-install cleanup OK'
