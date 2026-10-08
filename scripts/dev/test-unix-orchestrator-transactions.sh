#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
mkdir -p "$REPO_ROOT/.tmp"
TEST_ROOT="$(mktemp -d "$REPO_ROOT/.tmp/unix-orchestrator.XXXXXX")"
cleanup() { [[ "$TEST_ROOT" == "$REPO_ROOT/.tmp/unix-orchestrator."* ]] && rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$TEST_ROOT/repo/scripts/linux" "$TEST_ROOT/repo/templates/linux" "$TEST_ROOT/bin"
cp "$REPO_ROOT/deploy.sh" "$TEST_ROOT/repo/deploy.sh"
cp "$REPO_ROOT/scripts/linux/"*.sh "$TEST_ROOT/repo/scripts/linux/"
cp "$REPO_ROOT/templates/linux/"*.tpl "$TEST_ROOT/repo/templates/linux/"
# Fixtures execute actual control flow with mock service commands. Only the
# copied root guard and host paths change; production source stays protected.
escaped="${TEST_ROOT//&/\\&}"
for script in manage-deployment-transaction.sh app-package-lifecycle.sh common.sh install-nginx-reverse-proxy.sh install-apache-reverse-proxy.sh uninstall-node-service.sh; do
  sed -e '/Managed deployment transaction requires root/d' -e '/Run as root or with sudo/d' \
    -e "s#/usr/local/etc/#$escaped/local-etc/#g" -e "s#/usr/local/libexec/#$escaped/local-exec/#g" \
    -e "s#/Library/LaunchDaemons/#$escaped/launchd/#g" \
    -e "s#/etc/#$escaped/etc/#g" -e "s# /etc # $escaped/etc #g" -e "s#/run/systemd/#$escaped/run/systemd/#g" \
    "$REPO_ROOT/scripts/linux/$script" > "$TEST_ROOT/repo/scripts/linux/$script"
done
sed -e '/^if \[\[ "${EUID}" -ne 0 \]\]; then$/,/^fi$/d' -e "s#/etc/#$escaped/etc/#g" \
  -e "s#/Library/LaunchDaemons/#$escaped/launchd/#g" \
  "$REPO_ROOT/scripts/linux/import-app-package.sh" > "$TEST_ROOT/repo/scripts/linux/import-app-package.actual.sh"
cat > "$TEST_ROOT/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
set -e
if [[ "${1:-}" == env ]]; then
  shift
  while [[ "${1:-}" == *=* ]]; do export "$1"; shift; done
fi
exec "$@"
MOCK
cat > "$TEST_ROOT/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -e
printf '%s\n' "systemctl $*" >> "$ORCHESTRATOR_TRACE"
action="$1"; shift
name=""
for item in "$@"; do [[ "$item" == -* ]] || { name="${item%.service}"; break; }; done
state="$ORCHESTRATOR_CASE/state/$name"
case "$action" in
  show)
    if [[ "$*" == *ActiveState* ]]; then cat "$state"; else printf 'loaded\n'; fi ;;
  is-active)
    value="$(cat "$state")"; [[ "$*" == *--quiet* ]] || printf '%s\n' "$value"
    [[ "$value" == active || "$value" == reloading ]] ;;
  is-enabled) printf 'disabled\n'; exit 1 ;;
  stop) printf 'inactive\n' > "$state" ;;
  start) printf 'active\n' > "$state" ;;
  reload|restart)
    if [[ "$FAIL_STAGE" == proxy || "$FAIL_STAGE" == apache-reload ]]; then exit 43; fi
    printf 'active\n' > "$state" ;;
  enable|disable|unmask|mask|daemon-reload) exit 0 ;;
  *) exit 90 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/nginx" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == -t ]]
MOCK
cat > "$TEST_ROOT/bin/ps" <<'MOCK'
#!/usr/bin/env bash
if [[ "${ORCHESTRATOR_MONITOR_BUSY:-false}" == true ]]; then
  printf '91234 0 bash /usr/local/sbin/wrapper_test-healthcheck.sh %s\n' "$ORCHESTRATOR_MONITOR_CONFIG"
fi
exit 0
MOCK
cat > "$TEST_ROOT/bin/crontab" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == -l ]]; then cat "$ORCHESTRATOR_CASE/crontab"; else cp "$1" "$ORCHESTRATOR_CASE/crontab"; fi
MOCK
cat > "$TEST_ROOT/bin/apache2ctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$FAIL_STAGE" != apache-test ]]
MOCK
cat > "$TEST_ROOT/bin/a2enmod" <<'MOCK'
#!/usr/bin/env bash
set -e
for module in "$@"; do
  for extension in load conf; do
    ln -sf "../mods-available/$module.$extension" "$ORCHESTRATOR_APACHE/mods-enabled/$module.$extension"
  done
done
MOCK
cat > "$TEST_ROOT/bin/a2ensite" <<'MOCK'
#!/usr/bin/env bash
ln -sf "../sites-available/$1.conf" "$ORCHESTRATOR_APACHE/sites-enabled/$1.conf"
MOCK
cat > "$TEST_ROOT/bin/service" <<'MOCK'
#!/usr/bin/env bash
state="$ORCHESTRATOR_CASE/state/$1"
case "$2" in
  status|onestatus) [[ "$(cat "$state")" == active ]] ;;
  start|onestart|restart) printf 'active\n' > "$state" ;;
  stop|onestop) printf 'inactive\n' > "$state" ;;
  *) exit 92 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/rc-service" <<'MOCK'
#!/usr/bin/env bash
exec service "$@"
MOCK
cat > "$TEST_ROOT/bin/rcctl" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" != -f ]] || shift
case "$1" in check) exec service "$2" status ;; start|stop) exec service "$2" "$1" ;; disable) exit 0 ;; *) exit 93 ;; esac
MOCK
cat > "$TEST_ROOT/bin/launchctl" <<'MOCK'
#!/usr/bin/env bash
action="$1"; shift
case "$action" in
  print-disabled) printf '"wrapper_test" => %s\n"wrapper_test-healthcheck" => true\n' "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test.disabled")"; exit 0 ;;
esac
for argument in "$@"; do last="$argument"; done
name="${last##*/}"; name="${name%.plist}"
case "$action" in
  print) [[ "$(cat "$ORCHESTRATOR_CASE/state/$name")" == active ]] ;;
  enable) printf 'false\n' > "$ORCHESTRATOR_CASE/state/$name.disabled" ;;
  disable) printf 'true\n' > "$ORCHESTRATOR_CASE/state/$name.disabled" ;;
  bootout) printf 'inactive\n' > "$ORCHESTRATOR_CASE/state/$name" ;;
  bootstrap|kickstart) printf 'active\n' > "$ORCHESTRATOR_CASE/state/$name" ;;
  *) exit 94 ;;
esac
MOCK
cat > "$TEST_ROOT/repo/scripts/linux/install-node-service.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/app-package-lifecycle.sh"
CONFIG_FILE="$1"; load_config_file CONFIG_FILE "$(cd "$SCRIPT_DIR/../.." && pwd)" "$CONFIG_FILE"
managed_mutation_begin
if [[ "$MANAGED_MUTATION_OWNS_JOURNAL" == true ]]; then package_stop_app_service systemd wrapper_test; fi
[[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == inactive ]] || { echo 'Preparation began before service stop.' >&2; exit 91; }
transaction_record_file "$ENV_FILE"
printf 'new-runtime\n' > "$ENV_FILE"
transaction_record_file "$ORCHESTRATOR_CASE/app.service"
printf 'new-unit\n' > "$ORCHESTRATOR_CASE/app.service"
systemctl enable wrapper_test
systemctl start wrapper_test
[[ "$FAIL_STAGE" != service ]] || exit 42
MOCK
cat > "$TEST_ROOT/repo/scripts/linux/import-app-package.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
CONFIG_FILE="$1"; load_config_file CONFIG_FILE "$(cd "$SCRIPT_DIR/../.." && pwd)" "$CONFIG_FILE"
mutation_locks_acquire
deployment_assert_no_pending_transactions "$NODE_DEPLOY_TRANSACTION_DIR"
[[ "$(cat "$NODE_DEPLOY_TRANSACTION_DIR/package-state-path")" == "$4" ]]
printf 'current-package-transaction\n' > "$4"
MOCK
cat > "$TEST_ROOT/repo/scripts/linux/install-healthcheck-scheduler.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
CONFIG_FILE="$1"; load_config_file CONFIG_FILE "$(cd "$SCRIPT_DIR/../.." && pwd)" "$CONFIG_FILE"
managed_mutation_begin
transaction_record_file "$ORCHESTRATOR_CASE/health.env"
printf 'new-health\n' > "$ORCHESTRATOR_CASE/health.env"
transaction_record_root_crontab
printf '# node-enterprise-deploy-kit:wrapper_test:healthcheck:start\nnew-monitor\n# node-enterprise-deploy-kit:wrapper_test:healthcheck:end\nunrelated-after\n' > "$ORCHESTRATOR_CASE/crontab"
[[ "$FAIL_STAGE" != scheduler ]] || exit 45
MOCK
chmod 0755 "$TEST_ROOT/bin/"* "$TEST_ROOT/repo/scripts/linux/"*.sh
export PATH="$TEST_ROOT/bin:$PATH"
export SHARED_CONTROL_LOCK_ROOT="$TEST_ROOT/shared"
export DEPLOYMENT_TRANSACTION_ROOT="$TEST_ROOT/transactions"
export SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
export ORCHESTRATOR_TRACE="$TEST_ROOT/trace"
export ORCHESTRATOR_APACHE="$TEST_ROOT/etc/apache2"
export ORCHESTRATOR_MONITOR_CONFIG="$TEST_ROOT/etc/node-enterprise-deploy-kit/wrapper_test.env"
mkdir -p "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/run/systemd/system" "$TEST_ROOT/etc/node-enterprise-deploy-kit"
mkdir -p "$ORCHESTRATOR_APACHE"/{mods-enabled,mods-available,sites-enabled,sites-available}

run_case() {
  export FAIL_STAGE="$1"
  export ORCHESTRATOR_MONITOR_BUSY=false
  if [[ "$FAIL_STAGE" == legacy-monitor-busy ]]; then ORCHESTRATOR_MONITOR_BUSY=true; fi
  export ORCHESTRATOR_CASE="$TEST_ROOT/case-$FAIL_STAGE"
  mkdir -p "$ORCHESTRATOR_CASE/state" "$ORCHESTRATOR_CASE/proxy" "$ORCHESTRATOR_CASE/logs"
  printf 'activating\n' > "$ORCHESTRATOR_CASE/state/wrapper_test"
  printf 'inactive\n' > "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck.timer"
  printf 'inactive\n' > "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck"
  if [[ "$FAIL_STAGE" == skip-health ]]; then printf 'active\n' > "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck.timer"; fi
  printf 'active\n' > "$ORCHESTRATOR_CASE/state/nginx"
  printf 'active\n' > "$ORCHESTRATOR_CASE/state/apache2"
  printf 'old-runtime\n' > "$ORCHESTRATOR_CASE/runtime.env"
  printf 'old-unit\n' > "$ORCHESTRATOR_CASE/app.service"
  printf 'old-proxy\n' > "$ORCHESTRATOR_CASE/proxy/wrapper_test.conf"
  printf 'old-health\n' > "$ORCHESTRATOR_CASE/health.env"
  printf '# node-enterprise-deploy-kit:wrapper_test:healthcheck:start\nold-monitor\n# node-enterprise-deploy-kit:wrapper_test:healthcheck:end\nunrelated-before\n' > "$ORCHESTRATOR_CASE/crontab"
  runtime=node; [[ "$FAIL_STAGE" != explicit ]] || runtime=unsupported
  proxy=nginx
  if [[ "$FAIL_STAGE" == apache-* ]]; then
    proxy=apache
    for module in proxy proxy_http proxy_wstunnel headers rewrite; do
      for extension in load conf; do
        printf 'available-%s\n' "$module" > "$ORCHESTRATOR_APACHE/mods-available/$module.$extension"
        rm -f "$ORCHESTRATOR_APACHE/mods-enabled/$module.$extension"
      done
    done
    ln -s ../mods-available/headers.load "$ORCHESTRATOR_APACHE/mods-enabled/headers.load"
    printf 'unrelated-module\n' > "$ORCHESTRATOR_APACHE/mods-enabled/unrelated.load"
    printf 'old-apache\n' > "$ORCHESTRATOR_APACHE/sites-available/wrapper_test.conf"
    rm -f "$ORCHESTRATOR_APACHE/sites-enabled/wrapper_test.conf"
  fi
  cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME='wrapper_test'
APP_RUNTIME='$runtime'
SERVICE_MANAGER='systemd'
APP_DIR='$ORCHESTRATOR_CASE/app'
APP_DISPLAY_NAME='Wrapper test'
APP_PORT='3000'
PUBLIC_HOSTNAME='example.test'
HEALTH_URL='http://127.0.0.1:3000/health'
ENV_FILE='$ORCHESTRATOR_CASE/runtime.env'
LOG_DIR='$ORCHESTRATOR_CASE/logs'
PROXY_LOG_DIR='$ORCHESTRATOR_CASE/proxy-logs'
BACKUP_DIR='$ORCHESTRATOR_CASE/backups'
NGINX_CONFIG_DIR='$ORCHESTRATOR_CASE/proxy'
NGINX_SITE_NAME='wrapper_test'
REVERSE_PROXY='$proxy'
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS='0'
HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS='0'
SKIP_PREFLIGHT='true'
SKIP_PACKAGE_IMPORT='true'
REQUIRE_POST_DEPLOY_HEALTH_CHECK='false'
CONFIG
  if [[ "$FAIL_STAGE" == active-package ]]; then printf "SKIP_PACKAGE_IMPORT=false\nPACKAGE_PATH='fixture.tar'\n" >> "$ORCHESTRATOR_CASE/app.env"; fi
  if [[ "$FAIL_STAGE" == skip-health ]]; then printf 'SKIP_HEALTH_CHECK=true\n' >> "$ORCHESTRATOR_CASE/app.env"; fi
  : > "$ORCHESTRATOR_TRACE"
  expected=0
  case "$FAIL_STAGE" in service) expected=42 ;; proxy|apache-reload) expected=43 ;; scheduler) expected=45 ;; explicit|apache-test|legacy-monitor-busy) expected=1 ;; esac
  result=0
  bash "$TEST_ROOT/repo/deploy.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1 || result=$?
  [[ "$result" == "$expected" ]] || { cat "$ORCHESTRATOR_CASE/output" >&2; echo "Unexpected result for $FAIL_STAGE: $result" >&2; exit 1; }
  [[ ! -e "$TEST_ROOT/locks/wrapper_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]
  if [[ "$FAIL_STAGE" == legacy-monitor-busy ]]; then
    [[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == activating ]]
    grep -q 'existing privileged health monitor has not exited' "$ORCHESTRATOR_CASE/output"
    if grep -Fxq 'systemctl stop wrapper_test' "$ORCHESTRATOR_TRACE"; then echo 'App stopped before legacy monitor drained.' >&2; exit 1; fi
  else [[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == active ]]; fi
  if [[ "$expected" -ne 0 ]]; then
    [[ "$(cat "$ORCHESTRATOR_CASE/runtime.env")" == old-runtime ]]
    [[ "$(cat "$ORCHESTRATOR_CASE/app.service")" == old-unit ]]
    [[ "$(cat "$ORCHESTRATOR_CASE/proxy/wrapper_test.conf")" == old-proxy ]]
    [[ "$(cat "$ORCHESTRATOR_CASE/health.env")" == old-health ]]
    [[ "$(cat "$ORCHESTRATOR_CASE/state/nginx")" == active ]]
    [[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck.timer")" == inactive ]]
    grep -q '^old-monitor$' "$ORCHESTRATOR_CASE/crontab"
    if [[ "$FAIL_STAGE" == scheduler ]]; then grep -q '^unrelated-after$' "$ORCHESTRATOR_CASE/crontab"; fi
    if [[ "$proxy" == apache ]]; then
      [[ "$(cat "$ORCHESTRATOR_APACHE/sites-available/wrapper_test.conf")" == old-apache ]]
      [[ ! -e "$ORCHESTRATOR_APACHE/sites-enabled/wrapper_test.conf" && ! -L "$ORCHESTRATOR_APACHE/sites-enabled/wrapper_test.conf" ]]
      [[ "$(cat "$ORCHESTRATOR_APACHE/mods-enabled/headers.load")" == available-headers ]]
      [[ "$(cat "$ORCHESTRATOR_APACHE/mods-enabled/unrelated.load")" == unrelated-module ]]
      for module in proxy proxy_http proxy_wstunnel rewrite; do
        [[ ! -e "$ORCHESTRATOR_APACHE/mods-enabled/$module.load" && ! -e "$ORCHESTRATOR_APACHE/mods-enabled/$module.conf" ]]
      done
      [[ "$(cat "$ORCHESTRATOR_CASE/state/apache2")" == active ]]
    fi
  else
    [[ "$(cat "$ORCHESTRATOR_CASE/runtime.env")" == new-runtime ]]
    grep -q 'Managed by node-enterprise-deploy-kit' "$ORCHESTRATOR_CASE/proxy/wrapper_test.conf"
    if [[ "$FAIL_STAGE" == skip-health ]]; then
      [[ "$(cat "$ORCHESTRATOR_CASE/health.env")" == old-health && "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck.timer")" == active ]]
      grep -q '^old-monitor$' "$ORCHESTRATOR_CASE/crontab"
    else [[ "$(cat "$ORCHESTRATOR_CASE/health.env")" == new-health ]]; fi
  fi
}

# Replacing a manager/runtime/proxy is an explicit migration. A known previous
# protected profile must reject it before any old or new service is touched.
previous_config="$TEST_ROOT/etc/node-enterprise-deploy-kit/wrapper_test.env"
for migration in manager runtime proxy tomcat-service; do
  export ORCHESTRATOR_CASE="$TEST_ROOT/migration-$migration"
  mkdir -p "$ORCHESTRATOR_CASE/state" "$ORCHESTRATOR_CASE/app"
  printf 'active\n' > "$ORCHESTRATOR_CASE/state/old-service"
  printf 'inactive\n' > "$ORCHESTRATOR_CASE/state/new-service"
  printf 'original-app\n' > "$ORCHESTRATOR_CASE/app/sentinel"
  old_runtime=node; incoming_runtime=node; incoming_manager=systemd; incoming_proxy=nginx
  old_tomcat=old-service; incoming_tomcat=old-service
  case "$migration" in
    manager) incoming_manager=openrc ;;
    runtime) incoming_runtime=tomcat ;;
    proxy) incoming_proxy=apache ;;
    tomcat-service) old_runtime=tomcat; incoming_runtime=tomcat; incoming_tomcat=new-service ;;
  esac
  cat > "$previous_config" <<CONFIG
APP_NAME=wrapper_test
SERVICE_MANAGER=systemd
APP_RUNTIME=$old_runtime
REVERSE_PROXY=nginx
TOMCAT_SERVICE=$old_tomcat
CONFIG
  cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME=wrapper_test
SERVICE_MANAGER=$incoming_manager
APP_RUNTIME=$incoming_runtime
REVERSE_PROXY=$incoming_proxy
TOMCAT_SERVICE=$incoming_tomcat
APP_DIR='$ORCHESTRATOR_CASE/app'
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
SKIP_PREFLIGHT=true
SKIP_PACKAGE_IMPORT=true
CONFIG
  : > "$ORCHESTRATOR_TRACE"
  if bash "$TEST_ROOT/repo/deploy.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
    echo "Automatic $migration migration was unexpectedly accepted." >&2; exit 1
  fi
  grep -q 'In-place service-manager, runtime, proxy-type, or Tomcat-service migration' "$ORCHESTRATOR_CASE/output"
  [[ ! -s "$ORCHESTRATOR_TRACE" ]]
  [[ "$(cat "$ORCHESTRATOR_CASE/state/old-service")" == active && "$(cat "$ORCHESTRATOR_CASE/state/new-service")" == inactive ]]
  [[ "$(cat "$ORCHESTRATOR_CASE/app/sentinel")" == original-app ]]
  [[ ! -e "$TEST_ROOT/locks/wrapper_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]
done
export ORCHESTRATOR_CASE="$TEST_ROOT/migration-compatible-aliases"
mkdir -p "$ORCHESTRATOR_CASE/state" "$TEST_ROOT/etc/init.d"
printf 'active\n' > "$ORCHESTRATOR_CASE/state/old-service"
printf 'active\n' > "$ORCHESTRATOR_CASE/state/apache2"
printf '#!/bin/sh\n' > "$TEST_ROOT/etc/init.d/old-service"
chmod 0755 "$TEST_ROOT/etc/init.d/old-service"
cat > "$previous_config" <<CONFIG
APP_NAME=wrapper_test
SERVICE_MANAGER=sysvinit
APP_RUNTIME=apache-tomcat
REVERSE_PROXY=httpd
TOMCAT_SERVICE=old-service
CONFIG
cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME=wrapper_test
SERVICE_MANAGER=systemv
APP_RUNTIME=tomcat
REVERSE_PROXY=apache
TOMCAT_SERVICE=old-service
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
CONFIG
compatible_journal="$TEST_ROOT/transactions/wrapper_test.lock.managed-transaction.compatible"
bash "$TEST_ROOT/repo/scripts/linux/manage-deployment-transaction.sh" begin "$ORCHESTRATOR_CASE/app.env" "$compatible_journal"
[[ "$(cat "$ORCHESTRATOR_CASE/state/old-service")" == active ]]
bash "$TEST_ROOT/repo/scripts/linux/manage-deployment-transaction.sh" finish "$ORCHESTRATOR_CASE/app.env" "$compatible_journal"
rm "$previous_config"

# Old journals block both the wrapper and direct installer before any service
# probe/write, and a forged inherited journal cannot adopt a newly acquired lock.
for pending_case in legacy-managed legacy-package persistent-managed persistent-package; do
  pending_kind="${pending_case##*-}"
  export ORCHESTRATOR_CASE="$TEST_ROOT/pending-$pending_case"
  mkdir -p "$ORCHESTRATOR_CASE/state" "$ORCHESTRATOR_CASE/app"
  printf 'active\n' > "$ORCHESTRATOR_CASE/state/wrapper_test"
  printf 'original-app\n' > "$ORCHESTRATOR_CASE/app/sentinel"
  cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME=wrapper_test
APP_RUNTIME=node
SERVICE_MANAGER=systemd
REVERSE_PROXY=none
APP_DIR='$ORCHESTRATOR_CASE/app'
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
SKIP_PREFLIGHT=true
SKIP_PACKAGE_IMPORT=true
CONFIG
  pending_prefix="$TEST_ROOT/locks/wrapper_test.lock"
  if [[ "$pending_case" == persistent-* ]]; then
    pending_prefix="$TEST_ROOT/transactions/wrapper_test.lock"
    mkdir "$TEST_ROOT/locks/wrapper_test.lock"
    printf 'Token=%s\n' 'killed-deployment' > "$TEST_ROOT/locks/wrapper_test.lock/owner"
    rm "$TEST_ROOT/locks/wrapper_test.lock/owner"
    rmdir "$TEST_ROOT/locks/wrapper_test.lock" "$TEST_ROOT/locks"
  fi
  if [[ "$pending_kind" == managed ]]; then
    pending_path="$pending_prefix.managed-transaction.killed"
    mkdir "$pending_path"
    printf '%s\n' 'node-enterprise-deploy-kit/managed-transaction/v1' > "$pending_path/schema"
    printf 'old-lock-token\n' > "$pending_path/app-lock-token"
    printf '%s\n' "$TEST_ROOT/locks/wrapper_test.lock" > "$pending_path/app-lock-path"
    printf 'manual-recovery-evidence\n' > "$pending_path/evidence"
  else
    pending_path="$pending_prefix.package-transaction.killed.state"
    printf 'manual-recovery-evidence\n' > "$pending_path"
  fi
  : > "$ORCHESTRATOR_TRACE"
  if bash "$TEST_ROOT/repo/deploy.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
    echo 'Deployment unexpectedly ignored retained recovery evidence.' >&2; exit 1
  fi
  grep -q 'Unfinished deployment recovery state requires manual recovery' "$ORCHESTRATOR_CASE/output"
  if bash "$TEST_ROOT/repo/scripts/linux/install-node-service.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
    echo 'Standalone installer unexpectedly ignored retained recovery evidence.' >&2; exit 1
  fi
  grep -q 'Unfinished deployment recovery state requires manual recovery' "$ORCHESTRATOR_CASE/output"
  printf 'original-service-control\n' > "$TEST_ROOT/etc/systemd/system/wrapper_test.service"
  if bash "$TEST_ROOT/repo/scripts/linux/uninstall-node-service.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
    echo 'Uninstaller unexpectedly ignored retained recovery evidence.' >&2; exit 1
  fi
  grep -q 'Unfinished deployment recovery state requires manual recovery' "$ORCHESTRATOR_CASE/output"
  [[ "$(cat "$TEST_ROOT/etc/systemd/system/wrapper_test.service")" == original-service-control ]]
  if [[ "$pending_kind" == managed ]]; then
    if NODE_DEPLOY_TRANSACTION_DIR="$pending_path" bash "$TEST_ROOT/repo/scripts/linux/install-node-service.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
      echo 'A stale journal unexpectedly adopted the new application lock.' >&2; exit 1
    fi
    grep -q 'inherited journal does not belong' "$ORCHESTRATOR_CASE/output"
    [[ "$(cat "$pending_path/evidence")" == manual-recovery-evidence ]]; rm -r -- "$pending_path"
  else
    [[ "$(cat "$pending_path")" == manual-recovery-evidence ]]; rm -- "$pending_path"
  fi
  [[ ! -s "$ORCHESTRATOR_TRACE" && "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == active ]]
  [[ "$(cat "$ORCHESTRATOR_CASE/app/sentinel")" == original-app ]]
  [[ ! -e "$TEST_ROOT/locks/wrapper_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]
done
export ORCHESTRATOR_CASE="$TEST_ROOT/pending-previous-root"
mkdir -p "$ORCHESTRATOR_CASE/state" "$TEST_ROOT/previous-transactions/wrapper_test.lock.managed-transaction.killed"
printf 'active\n' > "$ORCHESTRATOR_CASE/state/wrapper_test"
cat > "$previous_config" <<CONFIG
APP_NAME=wrapper_test
APP_RUNTIME=node
SERVICE_MANAGER=systemd
REVERSE_PROXY=none
DEPLOYMENT_TRANSACTION_ROOT='$TEST_ROOT/previous-transactions'
CONFIG
cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME=wrapper_test
APP_RUNTIME=node
SERVICE_MANAGER=systemd
REVERSE_PROXY=none
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
DEPLOYMENT_TRANSACTION_ROOT='$TEST_ROOT/transactions'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SKIP_PREFLIGHT=true
SKIP_PACKAGE_IMPORT=true
CONFIG
: > "$ORCHESTRATOR_TRACE"
if bash "$TEST_ROOT/repo/deploy.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
  echo 'Changing transaction root unexpectedly hid the previous recovery journal.' >&2; exit 1
fi
grep -q 'Unfinished deployment recovery state requires manual recovery' "$ORCHESTRATOR_CASE/output"
if bash "$TEST_ROOT/repo/scripts/linux/uninstall-node-service.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/output" 2>&1; then
  echo 'Uninstaller unexpectedly hid the previous recovery journal.' >&2; exit 1
fi
grep -q 'Unfinished deployment recovery state requires manual recovery' "$ORCHESTRATOR_CASE/output"
[[ -f "$previous_config" && -d "$TEST_ROOT/previous-transactions/wrapper_test.lock.managed-transaction.killed" ]]
[[ ! -s "$ORCHESTRATOR_TRACE" && "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == active ]]
[[ ! -e "$TEST_ROOT/locks/wrapper_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]
rmdir "$TEST_ROOT/previous-transactions/wrapper_test.lock.managed-transaction.killed" "$TEST_ROOT/previous-transactions"
rm "$previous_config"
for phase in service proxy scheduler explicit apache-test apache-reload legacy-monitor-busy success active-package skip-health; do run_case "$phase"; done
export ORCHESTRATOR_MONITOR_BUSY=false
# A direct service installer owns its journal and must resume the old scheduler
# after quiescing it, without reinstalling the health configuration.
bash "$TEST_ROOT/repo/scripts/linux/install-node-service.sh" "$ORCHESTRATOR_CASE/app.env" > "$ORCHESTRATOR_CASE/standalone-output" 2>&1
[[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == active && "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck.timer")" == active ]]
grep -q '^old-monitor$' "$ORCHESTRATOR_CASE/crontab"
[[ ! -e "$TEST_ROOT/locks/wrapper_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]

# Exercise the actual importer CLI on a tiny local archive. Existing runtime or
# monitor registration requires the parent transaction; fresh staging succeeds.
mkdir "$TEST_ROOT/package-source"
printf 'console.log("staged-release");\n' > "$TEST_ROOT/package-source/server.js"
tar -cf "$TEST_ROOT/staged-release.tar" -C "$TEST_ROOT/package-source" .
package_sha="$(sha256sum "$TEST_ROOT/staged-release.tar" | awk '{print $1}')"
for import_scope in existing-runtime existing-monitor existing-cron staging; do
  export ORCHESTRATOR_CASE="$TEST_ROOT/import-$import_scope"
  mkdir -p "$ORCHESTRATOR_CASE/app" "$ORCHESTRATOR_CASE/state"
  printf 'original-app\n' > "$ORCHESTRATOR_CASE/app/sentinel"
  printf 'inactive\n' > "$ORCHESTRATOR_CASE/state/wrapper_test"
  printf 'unrelated-cron\n' > "$ORCHESTRATOR_CASE/crontab"
  import_manager=none
  if [[ "$import_scope" == existing-runtime ]]; then import_manager=systemd; fi
  if [[ "$import_scope" == existing-monitor ]]; then printf 'previous-monitor\n' > "$previous_config"; fi
  if [[ "$import_scope" == existing-cron ]]; then
    printf '# node-enterprise-deploy-kit:wrapper_test:healthcheck:start\nold-monitor\n# node-enterprise-deploy-kit:wrapper_test:healthcheck:end\nunrelated-cron\n' > "$ORCHESTRATOR_CASE/crontab"
  fi
  cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME=wrapper_test
APP_RUNTIME=node
APP_FRAMEWORK=node
SERVICE_MANAGER=$import_manager
APP_DIR='$ORCHESTRATOR_CASE/app'
START_SCRIPT=server.js
PACKAGE_EXPECTED_FILES=server.js
PACKAGE_MINIMUM_FREE_SPACE_MB=0
BACKUP_DIR='$ORCHESTRATOR_CASE/backups'
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
DEPLOYMENT_TRANSACTION_ROOT='$TEST_ROOT/transactions'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
CONFIG
  : > "$ORCHESTRATOR_TRACE"
  if [[ "$import_scope" == staging ]]; then
    bash "$TEST_ROOT/repo/scripts/linux/import-app-package.actual.sh" "$ORCHESTRATOR_CASE/app.env" "$TEST_ROOT/staged-release.tar" "$package_sha" > "$ORCHESTRATOR_CASE/output" 2>&1
    [[ -f "$ORCHESTRATOR_CASE/app/server.js" && -f "$ORCHESTRATOR_CASE/app/.node-enterprise-deploy.json" && ! -e "$ORCHESTRATOR_CASE/app/sentinel" ]]
    for leftover in "$TEST_ROOT/transactions/wrapper_test.lock".package-transaction.*.state; do [[ ! -e "$leftover" ]]; done
  else
    if bash "$TEST_ROOT/repo/scripts/linux/import-app-package.actual.sh" "$ORCHESTRATOR_CASE/app.env" "$TEST_ROOT/staged-release.tar" "$package_sha" > "$ORCHESTRATOR_CASE/output" 2>&1; then
      echo 'Standalone importer accepted an existing registered deployment.' >&2; exit 1
    fi
    grep -q 'Standalone package import is limited to staging' "$ORCHESTRATOR_CASE/output"
    [[ "$(cat "$ORCHESTRATOR_CASE/app/sentinel")" == original-app && ! -e "$ORCHESTRATOR_CASE/app/server.js" ]]
    if grep -q '^systemctl stop ' "$ORCHESTRATOR_TRACE"; then echo 'Standalone guard stopped an existing runtime.' >&2; exit 1; fi
  fi
  [[ ! -e "$TEST_ROOT/locks/wrapper_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]
  [[ "$import_scope" != existing-monitor ]] || rm "$previous_config"
done

# Run actual snapshot/restore dispatch through each native CLI shape. Commands
# remain mocked; actual SysV/OpenRC symlink membership is covered separately by
# test-unix-hardening.sh on a native filesystem.
mkdir -p "$TEST_ROOT/etc/init.d" "$TEST_ROOT/local-etc/rc.d" "$TEST_ROOT/launchd"
for native_manager in systemv openrc launchd bsdrc; do
  for prior_state in active inactive; do
    export ORCHESTRATOR_CASE="$TEST_ROOT/control-$native_manager-$prior_state"
    mkdir -p "$ORCHESTRATOR_CASE/state"
    printf '%s\n' "$prior_state" > "$ORCHESTRATOR_CASE/state/wrapper_test"
    printf 'inactive\n' > "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck"
    printf 'true\n' > "$ORCHESTRATOR_CASE/state/wrapper_test.disabled"
    printf '#!/bin/sh\n' > "$TEST_ROOT/etc/init.d/wrapper_test"
    printf '#!/bin/sh\n' > "$TEST_ROOT/local-etc/rc.d/wrapper_test"
    chmod 0755 "$TEST_ROOT/etc/init.d/wrapper_test" "$TEST_ROOT/local-etc/rc.d/wrapper_test"
    printf '<plist/>\n' > "$TEST_ROOT/launchd/wrapper_test.plist"
    printf '<plist/>\n' > "$TEST_ROOT/launchd/wrapper_test-healthcheck.plist"
    cat > "$ORCHESTRATOR_CASE/app.env" <<CONFIG
APP_NAME=wrapper_test
APP_RUNTIME=node
SERVICE_MANAGER=$native_manager
REVERSE_PROXY=none
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
REQUIRE_POST_DEPLOY_HEALTH_CHECK=false
CONFIG
    native_journal="$TEST_ROOT/transactions/wrapper_test.lock.managed-transaction.$native_manager.$prior_state"
    bash "$TEST_ROOT/repo/scripts/linux/manage-deployment-transaction.sh" begin "$ORCHESTRATOR_CASE/app.env" "$native_journal"
    bash "$TEST_ROOT/repo/scripts/linux/manage-deployment-transaction.sh" quiesce-health "$ORCHESTRATOR_CASE/app.env" "$native_journal"
    printf 'active\n' > "$ORCHESTRATOR_CASE/state/wrapper_test"
    printf 'active\n' > "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck"
    printf 'false\n' > "$ORCHESTRATOR_CASE/state/wrapper_test.disabled"
    bash "$TEST_ROOT/repo/scripts/linux/manage-deployment-transaction.sh" restore "$ORCHESTRATOR_CASE/app.env" "$native_journal"
    [[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test")" == "$prior_state" ]]
    if [[ "$native_manager" == launchd ]]; then
      [[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test.disabled")" == true ]]
      [[ "$(cat "$ORCHESTRATOR_CASE/state/wrapper_test-healthcheck")" == inactive ]]
    fi
    bash "$TEST_ROOT/repo/scripts/linux/manage-deployment-transaction.sh" finish "$ORCHESTRATOR_CASE/app.env" "$native_journal"
  done
done

# Exercise protected owner handoff and two different app names contending for
# the same proxy/native registry. Releasing a child must retain its parent's
# lock, and ownership changes must fail closed.
# shellcheck source=scripts/linux/common.sh
source "$TEST_ROOT/repo/scripts/linux/common.sh"
CONFIG_FILE="$ORCHESTRATOR_CASE/app.env"
load_config_file CONFIG_FILE "$TEST_ROOT/repo" "$CONFIG_FILE"
mutation_locks_acquire
bash -c 'source "$1"; CONFIG_FILE="$2"; load_config_file CONFIG_FILE "$3" "$CONFIG_FILE"; mutation_locks_acquire; mutation_locks_release' _ "$TEST_ROOT/repo/scripts/linux/common.sh" "$CONFIG_FILE" "$TEST_ROOT/repo"
[[ -d "$NODE_DEPLOY_APP_LOCK_PATH" && -d "$NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH" ]]
: > "$ORCHESTRATOR_TRACE"
if env -u NODE_DEPLOY_APP_LOCK_PATH -u NODE_DEPLOY_APP_LOCK_TOKEN -u NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH -u NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN \
  bash "$TEST_ROOT/repo/scripts/linux/uninstall-node-service.sh" "$CONFIG_FILE" > "$TEST_ROOT/uninstall-contention-output" 2>&1; then
  echo 'Uninstaller bypassed the application lock.' >&2; exit 1
fi
grep -q 'Another deployment is already active' "$TEST_ROOT/uninstall-contention-output"
[[ ! -s "$ORCHESTRATOR_TRACE" && -d "$NODE_DEPLOY_APP_LOCK_PATH" && -d "$NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH" ]]
if env -u NODE_DEPLOY_APP_LOCK_PATH -u NODE_DEPLOY_APP_LOCK_TOKEN -u NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH -u NODE_DEPLOY_SHARED_CONTROL_LOCK_TOKEN \
  bash -c 'source "$1"; APP_NAME=another_app; DEPLOYMENT_LOCK_ROOT="$2"; SHARED_CONTROL_LOCK_ROOT="$3"; SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0; mutation_locks_acquire' _ \
  "$TEST_ROOT/repo/scripts/linux/common.sh" "$TEST_ROOT/locks" "$TEST_ROOT/shared" > "$TEST_ROOT/contention-output" 2>&1; then
  echo 'Different applications bypassed the shared proxy lock.' >&2; exit 1
fi
[[ ! -e "$TEST_ROOT/locks/another_app.lock" ]]
grep -q 'shared service/proxy configuration lock' "$TEST_ROOT/contention-output"
saved_owner="$(cat "$NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH/owner")"
printf 'Token=%s\n' 'changed-owner' > "$NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH/owner"
if shared_control_lock_release > "$TEST_ROOT/ownership-output" 2>&1; then echo 'Changed ownership was released.' >&2; exit 1; fi
[[ -d "$NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH" ]]
printf '%s\n' "$saved_owner" > "$NODE_DEPLOY_SHARED_CONTROL_LOCK_PATH/owner"
mutation_locks_release
if [[ "$EUID" -ne 0 ]]; then
  if bash "$REPO_ROOT/scripts/linux/manage-deployment-transaction.sh" begin "$ORCHESTRATOR_CASE/app.env" "$TEST_ROOT/root-guard.managed-transaction.fixture" > "$TEST_ROOT/root-guard-output" 2>&1; then
    echo 'Production root guard unexpectedly allowed a non-root caller.' >&2; exit 1
  fi
  grep -q 'requires root' "$TEST_ROOT/root-guard-output"
  [[ ! -e "$TEST_ROOT/root-guard.managed-transaction.fixture" ]]
fi
echo 'Actual Unix orchestrator recovery passed for nested installer failure, Nginx/Apache reload failure, Apache module/site activation, scheduler failure, explicit exit, queued systemd restart, and success (isolated managers).'
