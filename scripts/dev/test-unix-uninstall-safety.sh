#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
mkdir -p "$REPO_ROOT/.tmp"
TEST_ROOT="$(mktemp -d "$REPO_ROOT/.tmp/unix-uninstall.XXXXXX")"
UNINSTALL_REAL_PS="$(command -v ps)"
UNINSTALL_NATIVE_KERNEL="$(uname -s)"
export UNINSTALL_REAL_PS UNINSTALL_NATIVE_KERNEL
cleanup() { [[ "$TEST_ROOT" == "$REPO_ROOT/.tmp/unix-uninstall."* ]] && rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$TEST_ROOT/repo/scripts/linux" "$TEST_ROOT/bin"
cp "$REPO_ROOT/scripts/linux/"*.sh "$TEST_ROOT/repo/scripts/linux/"
escaped="${TEST_ROOT//&/\\&}"
# Only the disposable copy loses its root guard and receives fixture paths.
sed -e '/Run as root or with sudo/d' -e "s#/usr/local/etc/#$escaped/local-etc/#g" \
  -e "s#/usr/local/sbin/#$escaped/local-sbin/#g" -e "s#/etc/#$escaped/etc/#g" \
  -e "s#/Library/LaunchDaemons/#$escaped/launchd/#g" \
  "$REPO_ROOT/scripts/linux/uninstall-node-service.sh" > "$TEST_ROOT/repo/scripts/linux/uninstall-node-service.sh"
cat > "$TEST_ROOT/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
cat > "$TEST_ROOT/bin/native-manager" <<'MOCK'
#!/usr/bin/env bash
set -u
tool="${0##*/}"
printf '%s\n' "$tool $*" >> "$UNINSTALL_CASE/trace"
state_dir="$UNINSTALL_CASE/state"
stop_runtime() {
  [[ "$UNINSTALL_PHASE" != stop-failure || "$1" != uninstall_test ]] || exit 71
  [[ "$UNINSTALL_PHASE" != scheduler-failure || "$1" == uninstall_test ]] || exit 72
  [[ "$UNINSTALL_PHASE" != surviving-runtime || "$1" != uninstall_test ]] || return 0
  printf 'inactive\n' > "$state_dir/$1"
}
case "$tool" in
  systemctl)
    action="$1"; shift; name="${1:-}"; name="${name%.service}"
    case "$action" in
      show)
        if [[ "$*" == *LoadState* ]]; then
          if [[ -f "$state_dir/$name" ]]; then echo loaded; else echo not-found; fi
        elif [[ "$UNINSTALL_PHASE" == unknown-state && "$name" == uninstall_test ]]; then echo unexpected
        elif [[ -f "$state_dir/$name" ]]; then cat "$state_dir/$name"; else echo inactive; fi ;;
      stop) stop_runtime "$name" ;;
      disable) [[ "$UNINSTALL_PHASE" != unregister-failure || "$name" != uninstall_test ]] || exit 73 ;;
      daemon-reload) ;;
      *) exit 90 ;;
    esac ;;
  service|rc-service)
    case "$2" in
      status|onestatus)
        [[ "$UNINSTALL_PHASE" != unknown-state ]] || exit 4
        [[ "$(cat "$state_dir/$1")" == active ]] || exit 3 ;;
      stop|onestop) stop_runtime "$1" ;;
      *) exit 91 ;;
    esac ;;
  rcctl)
    [[ "$1" != -f ]] || shift
    case "$1" in
      check) [[ "$UNINSTALL_PHASE" != unknown-state ]] || exit 4; [[ "$(cat "$state_dir/$2")" == active ]] || exit 1 ;;
      stop) stop_runtime "$2" ;;
      disable) [[ "$UNINSTALL_PHASE" != unregister-failure ]] || exit 73 ;;
      *) exit 92 ;;
    esac ;;
  launchctl)
    name="${2##*/}"
    case "$1" in
      print)
        [[ "$UNINSTALL_PHASE" != unknown-state || "$name" != uninstall_test ]] || exit 5
        [[ -f "$state_dir/$name" && "$(cat "$state_dir/$name")" == active ]] || exit 113 ;;
      bootout) stop_runtime "$name" ;;
      *) exit 93 ;;
    esac ;;
  update-rc.d|chkconfig) [[ "$UNINSTALL_PHASE" != unregister-failure ]] || exit 73 ;;
  rc-update)
    if [[ "$1" == show ]]; then
      [[ "$UNINSTALL_PHASE" == unregistered ]] || echo 'uninstall_test | default'
    else [[ "$UNINSTALL_PHASE" != unregister-failure ]] || exit 73; fi ;;
  crontab)
    if [[ "$1" == -l ]]; then
      [[ "$UNINSTALL_PHASE" != cron-read-failure ]] || { echo 'permission denied' >&2; exit 1; }
      cat "$UNINSTALL_CASE/crontab"
    else [[ "$UNINSTALL_PHASE" != cron-failure ]] || exit 74; cp "$1" "$UNINSTALL_CASE/crontab"; fi ;;
  ps)
    if [[ "$UNINSTALL_PHASE" == actual-process-list ]]; then exec "$UNINSTALL_REAL_PS" "$@"; fi
    if [[ "$UNINSTALL_PHASE" == old-monitor-busy ]]; then
      printf '99991 0 bash %s/local-sbin/uninstall_test-healthcheck.sh %s/etc/node-enterprise-deploy-kit/uninstall_test.env\n' "$UNINSTALL_ROOT" "$UNINSTALL_ROOT"
    fi ;;
  *) exit 94 ;;
esac
MOCK
for command in systemctl service rc-service rcctl launchctl update-rc.d chkconfig rc-update crontab ps; do
  cp "$TEST_ROOT/bin/native-manager" "$TEST_ROOT/bin/$command"
done
chmod 0755 "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH" UNINSTALL_ROOT="$TEST_ROOT"
for manager in systemd systemv openrc launchd bsdrc bsd-service; do
  if [[ "$manager" == bsd-service ]]; then mv "$TEST_ROOT/bin/rcctl" "$TEST_ROOT/rcctl.saved"; selected_manager=bsdrc
  else selected_manager="$manager"; fi
  for phase in success stop-failure surviving-runtime unknown-state missing old-monitor-busy cron-failure cron-read-failure malformed-cron unregister-failure unregistered scheduler-failure actual-process-list; do
    case "$phase" in
      old-monitor-busy|cron-failure|cron-read-failure|malformed-cron) [[ "$manager" == systemd ]] || continue ;;
      unregistered) [[ "$manager" == openrc ]] || continue ;;
      actual-process-list) [[ "$manager" == systemd && "$UNINSTALL_NATIVE_KERNEL" == Linux ]] || continue ;;
    esac
    [[ "$manager" != launchd && "$manager" != bsd-service || "$phase" != unregister-failure ]] || continue
    [[ "$manager" == systemd || "$manager" == launchd || "$phase" != scheduler-failure ]] || continue
    export UNINSTALL_PHASE="$phase" UNINSTALL_CASE="$TEST_ROOT/case-$manager-$phase"
    mkdir -p "$UNINSTALL_CASE/state" "$TEST_ROOT/etc/systemd/system" "$TEST_ROOT/etc/init.d" "$TEST_ROOT/etc/rc.d" \
      "$TEST_ROOT/local-etc/rc.d" "$TEST_ROOT/local-sbin" "$TEST_ROOT/launchd" "$TEST_ROOT/etc/node-enterprise-deploy-kit"
    printf 'active\n' > "$UNINSTALL_CASE/state/uninstall_test"
    printf 'active\n' > "$UNINSTALL_CASE/state/uninstall_test-healthcheck.timer"
    printf 'active\n' > "$UNINSTALL_CASE/state/uninstall_test-healthcheck"
    printf 'active\n' > "$UNINSTALL_CASE/state/uninstall_test-healthcheck.service"
    case "$selected_manager" in
      systemd) definition="$TEST_ROOT/etc/systemd/system/uninstall_test.service" ;;
      systemv|openrc) definition="$TEST_ROOT/etc/init.d/uninstall_test" ;;
      launchd) definition="$TEST_ROOT/launchd/uninstall_test.plist" ;;
      bsdrc) definition="$TEST_ROOT/etc/rc.d/uninstall_test" ;;
    esac
    printf '#!/bin/sh\noriginal-control\n' > "$definition"; chmod 0755 "$definition"
    printf 'protected-monitor\n' > "$TEST_ROOT/local-sbin/uninstall_test-healthcheck.sh"
    printf 'DEPLOYMENT_TRANSACTION_ROOT="%s/transactions"\n' "$TEST_ROOT" > "$TEST_ROOT/etc/node-enterprise-deploy-kit/uninstall_test.env"
    printf '# node-enterprise-deploy-kit:uninstall_test:healthcheck:start\nold-monitor\n# node-enterprise-deploy-kit:uninstall_test:healthcheck:end\nunrelated-cron\n' > "$UNINSTALL_CASE/crontab"
    if [[ "$phase" == malformed-cron ]]; then printf '# node-enterprise-deploy-kit:uninstall_test:healthcheck:start\nold-monitor\nunrelated-cron\n' > "$UNINSTALL_CASE/crontab"; fi
    if [[ "$phase" == missing ]]; then rm "$definition"; rm "$UNINSTALL_CASE/state/"*; fi
    cat > "$UNINSTALL_CASE/app.env" <<CONFIG
APP_NAME=uninstall_test
SERVICE_MANAGER=$selected_manager
BACKUP_DIR='$UNINSTALL_CASE/backups'
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
DEPLOYMENT_TRANSACTION_ROOT='$TEST_ROOT/transactions'
SHARED_CONTROL_LOCK_ROOT='$TEST_ROOT/shared'
SHARED_CONTROL_LOCK_TIMEOUT_SECONDS=0
HEALTHCHECK_QUIESCE_TIMEOUT_SECONDS=0
RUNNER_SCRIPT='$TEST_ROOT/local-sbin/uninstall_test-runner.sh'
CONFIG
    : > "$UNINSTALL_CASE/trace"
    if bash "$TEST_ROOT/repo/scripts/linux/uninstall-node-service.sh" "$UNINSTALL_CASE/app.env" > "$UNINSTALL_CASE/output" 2>&1; then result=0; else result=$?; fi
    case "$phase" in
      success|missing|unregistered|actual-process-list)
        [[ "$result" -eq 0 && ! -e "$definition" && ! -e "$TEST_ROOT/etc/node-enterprise-deploy-kit/uninstall_test.env" ]] || { cat "$UNINSTALL_CASE/output"; exit 1; }
        grep -Fxq unrelated-cron "$UNINSTALL_CASE/crontab"
        if [[ "$phase" != missing ]]; then [[ "$(cat "$UNINSTALL_CASE/state/uninstall_test")" == inactive ]]; fi ;;
      *)
        [[ "$result" -ne 0 && -f "$definition" && -f "$TEST_ROOT/etc/node-enterprise-deploy-kit/uninstall_test.env" ]] || { cat "$UNINSTALL_CASE/output"; exit 1; }
        grep -q original-control "$definition"
        if [[ "$phase" == old-monitor-busy || "$phase" == cron-failure || "$phase" == cron-read-failure || "$phase" == malformed-cron || "$phase" == scheduler-failure ]]; then
          [[ "$(cat "$UNINSTALL_CASE/state/uninstall_test")" == active ]]
        fi ;;
    esac
    [[ ! -e "$TEST_ROOT/locks/uninstall_test.lock" && ! -e "$TEST_ROOT/shared/shared-control.lock" ]]
    rm -f "$definition" "$TEST_ROOT/etc/node-enterprise-deploy-kit/uninstall_test.env"
  done
  [[ "$manager" != bsd-service ]] || mv "$TEST_ROOT/rcctl.saved" "$TEST_ROOT/bin/rcctl"
done
echo 'Unix uninstall safety passed: scheduler drain, inactive verification, native failure propagation, missing registration, and retained controls (isolated managers).'
