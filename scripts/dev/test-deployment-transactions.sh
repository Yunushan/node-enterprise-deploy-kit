#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
# shellcheck source=scripts/linux/app-package-lifecycle.sh
source "$REPO_ROOT/scripts/linux/app-package-lifecycle.sh"
fixture="$(mktemp -d)"
cleanup() { [[ -n "$fixture" && -d "$fixture" && "$fixture" != "/" ]] && rm -rf -- "$fixture"; }
trap cleanup EXIT
APP_NAME=transaction-test
runtime="$fixture/runtime.env"
proxy="$fixture/proxy.conf"
introduced="$fixture/monitor.sh"
printf '%s\n' old-runtime > "$runtime"
touch -t 200001010000 "$runtime"
printf '%s\n' old-proxy > "$proxy"
transaction_begin "$fixture/app.managed-transaction.first"
printf '%s\n' new-runtime > "$fixture/replacement"
copy_file_with_backup "$fixture/replacement" "$runtime" "$fixture/backups"
first_backup="$LAST_BACKUP_PATH"
[[ -z "$(find "$first_backup" -mtime +1 -print)" ]]
printf '%s\n' second-runtime > "$fixture/replacement"
copy_file_with_backup "$fixture/replacement" "$runtime" "$fixture/backups"
[[ "$LAST_BACKUP_PATH" != "$first_backup" && "$(cat "$first_backup")" == old-runtime ]]
printf '%s\n' new-proxy > "$fixture/replacement"
replace_file_with_backup "$fixture/replacement" "$proxy" "$fixture/backups"
printf '%s\n' new-monitor > "$fixture/replacement"
copy_file_with_backup "$fixture/replacement" "$introduced" "$fixture/backups"

crontab() {
  if [[ "$1" == -l ]]; then cat "$fixture/root.cron"; else cp "$1" "$fixture/root.cron"; fi
}
cat > "$fixture/root.cron" <<'CRON'
# unrelated original job
* * * * * original-job
# node-enterprise-deploy-kit:transaction-test:healthcheck:start
* * * * * old-monitor
# node-enterprise-deploy-kit:transaction-test:healthcheck:end
CRON
transaction_record_root_crontab
cat > "$fixture/root.cron" <<'CRON'
# unrelated original job
* * * * * original-job
# node-enterprise-deploy-kit:transaction-test:healthcheck:start
* * * * * new-monitor
# node-enterprise-deploy-kit:transaction-test:healthcheck:end
# another app concurrently added a job
* * * * * concurrent-job
CRON
transaction_restore_files
[[ "$(cat "$runtime")" == old-runtime && "$(cat "$proxy")" == old-proxy && ! -e "$introduced" ]] || {
  echo "Managed files did not return to their original state." >&2; exit 1;
}
grep -q old-monitor "$fixture/root.cron"
grep -q concurrent-job "$fixture/root.cron"
if grep -q new-monitor "$fixture/root.cron"; then echo "Failed cron block survived rollback." >&2; exit 1; fi
transaction_finish

# Execute the actual package rollback with controlled service-manager functions.
# Service start must observe both the original APP_DIR and restored configuration.
app="$fixture/app"
backup="$fixture/backups/app.previous.bak"
mkdir -p "$app" "$backup"
printf '%s\n' new-app > "$app/version"
printf '%s\n' old-app > "$backup/version"
transaction_begin "$fixture/app.managed-transaction.second"
transaction_record_file "$runtime"
printf '%s\n' failed-runtime > "$runtime"
RUNNING=true
package_app_service_is_running() { [[ "$RUNNING" == true ]]; }
package_stop_app_service() { RUNNING=false; }
package_restart_app_service_after_failure() {
  [[ "$(cat "$app/version")" == old-app && "$(cat "$runtime")" == old-runtime ]] || {
    echo "Previous service started before application and configuration recovery." >&2; return 1;
  }
  RUNNING=true
}
systemctl() { [[ "$1" == daemon-reload ]]; }
package_rollback_deployment_transaction "$app" "$backup" true systemd "$APP_NAME" true true
[[ "$RUNNING" == true ]]
transaction_finish

transaction_begin "$fixture/app.managed-transaction.third"
transaction_record_file "$runtime"
rm "$NODE_DEPLOY_TRANSACTION_DIR/file.0/content"
if transaction_restore_files; then echo "Missing snapshot did not fail closed." >&2; exit 1; fi
[[ -d "$NODE_DEPLOY_TRANSACTION_DIR" && "$(cat "$runtime")" == old-runtime ]]
transaction_finish
echo "Managed file, cron merge, package recovery ordering, and missing-snapshot checks OK"
