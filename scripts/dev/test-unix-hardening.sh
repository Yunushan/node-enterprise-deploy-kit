#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
mkdir -p "$REPO_ROOT/.tmp"
TEST_ROOT="$(mktemp -d "$REPO_ROOT/.tmp/unix-hardening.XXXXXX")"
RUNTIME_CONTROL_TEST_ROOT=""
cleanup() {
  [[ "$TEST_ROOT" == "$REPO_ROOT/.tmp/unix-hardening."* ]] || return 1
  rm -rf -- "$TEST_ROOT"
  if [[ "$RUNTIME_CONTROL_TEST_ROOT" == /tmp/node-edk-runtime-control.?????? ]]; then rm -rf -- "$RUNTIME_CONTROL_TEST_ROOT"; fi
}
trap cleanup EXIT
# shellcheck source=scripts/linux/runtime-hardening.sh
source "$REPO_ROOT/scripts/linux/runtime-hardening.sh"
expect_failure() {
  if "$@" > "$TEST_ROOT/failure-output" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi
}
(
  uname() { printf '%s\n' "$lock_test_platform"; }
  lock_test_platform=Darwin
  [[ "$(hardening_default_lock_root)" == /var/lib/node-enterprise-deploy-kit/locks ]]
  for lock_test_platform in Linux FreeBSD; do
    [[ "$(hardening_default_lock_root)" == /var/run/node-enterprise-deploy-kit ]]
  done
)

# Exercise BSD stat fallback on every host, including the special bits that
# distinguish a trusted sticky temporary parent from a writable directory.
(
  stat() {
    [[ "$1" == -f && "$2" == '%u %Op' ]] || return 1
    printf '0 %s\n' "$bsd_mode"
  }
  bsd_mode=41777
  [[ "$(hardening_stat "$TEST_ROOT")" == '0 1777' ]]
  hardening_assert_trusted_directory "$TEST_ROOT"
  bsd_mode=40777
  expect_failure hardening_assert_trusted_directory "$TEST_ROOT"
  bsd_mode=44755
  [[ "$(hardening_stat "$TEST_ROOT")" == '0 4755' ]]
  bsd_mode=100640
  [[ "$(hardening_stat "$TEST_ROOT")" == '0 640' ]]
  bsd_mode='invalid-mode'
  expect_failure hardening_stat "$TEST_ROOT"
)

# The final key must be a complete read record, including a single custom key.
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
for key_list in SINGLE 'FIRST,FINAL'; do
  keys=()
  while IFS= read -r key; do keys+=("$key"); done < <(runtime_env_key_list "$key_list")
  if [[ "$key_list" == SINGLE ]]; then [[ "${keys[*]}" == SINGLE ]]; else [[ "${keys[*]}" == 'FIRST FINAL' ]]; fi
done

# Exercise the actual status URL/probe functions. Native proxy integration
# verifies these defaults against a real hostname-routed HTTP endpoint.
sed -n '/^default_proxy_health_url() {/,/^}/p; /^probe_reverse_proxy_health() {/,/^}/p' \
  "$REPO_ROOT/scripts/linux/status-node-app.sh" > "$TEST_ROOT/status-probe-functions.sh"
(
  # Functions are extracted from the real status source at test runtime.
  # shellcheck disable=SC1090,SC1091
  source "$TEST_ROOT/status-probe-functions.sh"
  proxy_listen_port() { printf '8080\n'; }
  curl() { printf '%s\n' "$@" > "$TEST_ROOT/probe-options"; printf 'http_code=200\ntime_total=0.01\n'; }
  export REVERSE_PROXY_NORMALIZED=traefik
  export PUBLIC_HOSTNAME=app.example.test
  export HEALTH_TIMEOUT_SECONDS=5
  unset PROXY_HEALTH_URL
  export HEALTHCHECK_PATH=/
  REVERSE_PROXY_PROBE_URL="$(default_proxy_health_url)"
  [[ "$REVERSE_PROXY_PROBE_URL" == http://127.0.0.1:8080/ ]]
  probe_reverse_proxy_health > "$TEST_ROOT/probe-result"
  grep -Fxq -- '--no-location' "$TEST_ROOT/probe-options"
  grep -Fxq 'Host: app.example.test' "$TEST_ROOT/probe-options"
  grep -Fxq 'http://127.0.0.1:8080/' "$TEST_ROOT/probe-options"
  export HEALTHCHECK_PATH=ready
  [[ "$(default_proxy_health_url)" == http://127.0.0.1:8080/ready ]]
  unset HEALTHCHECK_PATH
  [[ "$(default_proxy_health_url)" == http://127.0.0.1:8080/health ]]
  export PROXY_HEALTH_URL=https://probe.example.test/ready
  REVERSE_PROXY_PROBE_URL="$(default_proxy_health_url)"
  probe_reverse_proxy_health > "$TEST_ROOT/probe-result"
  grep -Fxq 'https://probe.example.test/ready' "$TEST_ROOT/probe-options"
  if grep -Fq 'Host:' "$TEST_ROOT/probe-options"; then echo 'Explicit URL hostname was overridden.' >&2; exit 1; fi
  unset PROXY_HEALTH_URL
  export REVERSE_PROXY_NORMALIZED=none
  [[ -z "$(default_proxy_health_url)" ]]
)

# Execute the real timer installer and real unit rendering with only native
# control dispatch/permissions mocked and every output redirected into a fixture.
timer_fixture="$TEST_ROOT/timer-contract"
mkdir -p "$timer_fixture/scripts/linux" "$timer_fixture/templates/linux" "$timer_fixture/host"
sed -e '/^if \[\[.*EUID.*Run as root or with sudo/d' \
  -e "s#/etc/#$timer_fixture/host/etc/#g" \
  -e "s#/usr/local/#$timer_fixture/host/usr/local/#g" \
  "$REPO_ROOT/scripts/linux/install-healthcheck-timer.sh" > "$timer_fixture/scripts/linux/install-healthcheck-timer.sh"
cp "$REPO_ROOT/templates/linux/healthcheck.service.tpl" "$REPO_ROOT/templates/linux/healthcheck.timer.tpl" "$timer_fixture/templates/linux/"
printf 'fixture healthcheck\n' > "$timer_fixture/scripts/linux/node-healthcheck.sh"
cat > "$timer_fixture/scripts/linux/common.sh" <<'TIMER_COMMON'
# shellcheck disable=SC1090
source "$TIMER_REAL_COMMON"
managed_mutation_begin() { :; }
root_group_name() { printf 'root\n'; }
copy_file_with_backup() {
  [[ "$2" == "$TIMER_SANDBOX_ROOT/"* ]] || return 1
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
}
replace_file_with_backup() {
  [[ "$2" == "$TIMER_SANDBOX_ROOT/"* ]] || return 1
  cp "$1" "$2"
  rm "$1"
}
chown() { :; }
systemctl() { printf '%s\n' "$*" >> "$TIMER_DISPATCH_TRACE"; }
TIMER_COMMON
cat > "$timer_fixture/scripts/linux/runtime-hardening.sh" <<'TIMER_HARDENING'
hardening_prepare_control_directory() {
  [[ "$1" == "$TIMER_SANDBOX_ROOT/"* ]] || return 1
  mkdir -p "$1"
}
TIMER_HARDENING
for timer_case in omitted empty invalid zero negative duration valid; do
  expected_interval=60
  case "$timer_case" in
    omitted) timer_assignment='' ;;
    empty) timer_assignment="HEALTHCHECK_INTERVAL=''" ;;
    invalid) timer_assignment='HEALTHCHECK_INTERVAL=invalid' ;;
    zero) timer_assignment='HEALTHCHECK_INTERVAL=0' ;;
    negative) timer_assignment='HEALTHCHECK_INTERVAL=-2' ;;
    duration) timer_assignment='HEALTHCHECK_INTERVAL=1s' ;;
    valid) timer_assignment='HEALTHCHECK_INTERVAL=137'; expected_interval=137 ;;
  esac
  cat > "$timer_fixture/app.env" <<TIMER_CONFIG
APP_NAME=timer_contract
APP_DISPLAY_NAME='Timer contract'
LOG_DIR='$timer_fixture/logs'
BACKUP_DIR='$timer_fixture/backups'
HEALTHCHECK_STATE_DIR='$timer_fixture/state'
$timer_assignment
TIMER_CONFIG
  if ! TIMER_REAL_COMMON="$REPO_ROOT/scripts/linux/common.sh" TIMER_SANDBOX_ROOT="$timer_fixture" \
    TIMER_DISPATCH_TRACE="$timer_fixture/dispatch" bash "$timer_fixture/scripts/linux/install-healthcheck-timer.sh" "$timer_fixture/app.env" > "$timer_fixture/output" 2>&1; then
    cat "$timer_fixture/output" >&2
    exit 1
  fi
  grep -Fxq "OnUnitActiveSec=$expected_interval" "$timer_fixture/host/etc/systemd/system/timer_contract-healthcheck.timer"
  grep -Fxq 'enable --now timer_contract-healthcheck.timer' "$timer_fixture/dispatch"
done
echo 'Actual systemd timer installer defaults omitted/empty/invalid intervals to 60 and preserves a valid override.'

# Exercise the actual Traefik installer/rendering with host dispatch and the
# disposable validator mocked. A native root run also proves nobody can read
# the published route under a restrictive installer umask.
traefik_fixture="$TEST_ROOT/traefik-contract"
mkdir -p "$traefik_fixture/scripts/linux" "$traefik_fixture/templates/linux" "$traefik_fixture/bin"
sed '/^if \[\[.*EUID.*Run as root or with sudo/d' \
  "$REPO_ROOT/scripts/linux/install-traefik-reverse-proxy.sh" > "$traefik_fixture/scripts/linux/install-traefik-reverse-proxy.sh"
cp "$REPO_ROOT/templates/linux/traefik-dynamic.yml.tpl" "$traefik_fixture/templates/linux/"
cat > "$traefik_fixture/scripts/linux/common.sh" <<'TRAEFIK_COMMON'
# shellcheck disable=SC1090
source "$TRAEFIK_REAL_COMMON"
managed_mutation_begin() { :; }
transaction_record_file() { [[ "$1" == "$TRAEFIK_SANDBOX_ROOT/"* ]]; }
backup_file_if_exists() { LAST_BACKUP_PATH=''; }
chown() { :; }
reload_or_restart_service() { printf '%s\n' "$*" >> "$TRAEFIK_DISPATCH_TRACE"; }
TRAEFIK_COMMON
printf '#!/usr/bin/env bash\nexit 0\n' > "$traefik_fixture/bin/traefik"
printf '#!/usr/bin/env bash\n[[ "$3" == "$TRAEFIK_SANDBOX_ROOT/dynamic/route.yml" && -f "$3" ]]\n' > "$traefik_fixture/bin/validator-node"
chmod 0755 "$traefik_fixture/bin/traefik" "$traefik_fixture/bin/validator-node"
cat > "$traefik_fixture/app.env" <<TRAEFIK_CONFIG
APP_NAME=traefik_contract
APP_PORT=3000
PUBLIC_HOSTNAME=contract.example.test
LOG_DIR='$traefik_fixture/logs'
BACKUP_DIR='$traefik_fixture/backups'
NODE_BIN='$traefik_fixture/bin/validator-node'
TRAEFIK_SERVICE=fixture-traefik
TRAEFIK_DYNAMIC_DIR='$traefik_fixture/dynamic'
TRAEFIK_DYNAMIC_FILE='$traefik_fixture/dynamic/route.yml'
TRAEFIK_CONFIG
if [[ "$EUID" -eq 0 && "$(uname -s)" == Linux ]] && id nobody >/dev/null 2>&1; then chmod 0711 "$TEST_ROOT"; fi
for route_case in new unchanged-private; do
  if [[ "$route_case" == unchanged-private ]]; then chmod 0600 "$traefik_fixture/dynamic/route.yml"; fi
  if ! (umask 077; export PATH="$traefik_fixture/bin:$PATH"; \
    TRAEFIK_REAL_COMMON="$REPO_ROOT/scripts/linux/common.sh" TRAEFIK_SANDBOX_ROOT="$traefik_fixture" \
    TRAEFIK_DISPATCH_TRACE="$traefik_fixture/dispatch" bash "$traefik_fixture/scripts/linux/install-traefik-reverse-proxy.sh" "$traefik_fixture/app.env") > "$traefik_fixture/output" 2>&1; then
    cat "$traefik_fixture/output" >&2; exit 1
  fi
  grep -Fq 'http://127.0.0.1:3000' "$traefik_fixture/dynamic/route.yml"
  grep -Fxq 'fixture-traefik Traefik' "$traefik_fixture/dispatch"
  if [[ "$EUID" -eq 0 && "$(uname -s)" == Linux ]] && id nobody >/dev/null 2>&1; then
    [[ "$(stat -c %a "$traefik_fixture/dynamic")" == 755 && "$(stat -c %a "$traefik_fixture/dynamic/route.yml")" == 644 ]]
    runuser -u nobody -- cat "$traefik_fixture/dynamic/route.yml" > "$traefik_fixture/nonroot-read"
    cmp -s "$traefik_fixture/nonroot-read" "$traefik_fixture/dynamic/route.yml"
  fi
done
if [[ "$EUID" -eq 0 && "$(uname -s)" == Linux ]] && id nobody >/dev/null 2>&1; then
  echo 'Actual Traefik installer publishes a non-root-readable route under umask077, including an unchanged formerly-private route (host dispatch/validator mocked).'
else
  echo 'Actual Traefik installer/rendering contract passed; native non-root permission proof requires Linux root and nobody.'
fi

# Native inactive/disabled values may accompany a nonzero command status.
sed -n '/^systemd_status_value()/,/^}/p' "$REPO_ROOT/scripts/linux/status-node-app.sh" > "$TEST_ROOT/status-value-functions.sh"
# shellcheck disable=SC1091
source "$TEST_ROOT/status-value-functions.sh"
systemctl() { printf 'inactive\n'; return 3; }
[[ "$(systemd_status_value is-active fixture.timer)" == inactive ]]
systemctl() { return 4; }
[[ "$(systemd_status_value is-active fixture.timer)" == unknown ]]
unset -f systemctl

# Exercise actual installer functions with an existing unprivileged account.
# Only disposable /tmp ownership changes occur; no account/service is created.
if [[ "$EUID" -eq 0 && "$(uname -s)" == Linux ]] && id nobody >/dev/null 2>&1; then
  RUNTIME_CONTROL_TEST_ROOT="$(mktemp -d /tmp/node-edk-runtime-control.XXXXXX)"
  chmod 0711 "$RUNTIME_CONTROL_TEST_ROOT"
  mkdir -p "$RUNTIME_CONTROL_TEST_ROOT/scripts/linux" "$RUNTIME_CONTROL_TEST_ROOT/app" "$RUNTIME_CONTROL_TEST_ROOT/logs" "$RUNTIME_CONTROL_TEST_ROOT/private"
  cp "$REPO_ROOT/scripts/linux/"*.sh "$RUNTIME_CONTROL_TEST_ROOT/scripts/linux/"
  sed '/^require_root$/,$d' "$REPO_ROOT/scripts/linux/install-node-service.sh" > "$RUNTIME_CONTROL_TEST_ROOT/scripts/linux/install-functions.sh"
  nobody_group="$(id -gn nobody)"; nobody_uid="$(id -u nobody)"
  cat > "$RUNTIME_CONTROL_TEST_ROOT/app.env" <<CONFIG
APP_NAME=hardening_runtime
APP_DISPLAY_NAME='Hardening runtime'
APP_DIR='$RUNTIME_CONTROL_TEST_ROOT/app'
LOG_DIR='$RUNTIME_CONTROL_TEST_ROOT/logs'
ENV_FILE='$RUNTIME_CONTROL_TEST_ROOT/private/runtime.env'
BACKUP_DIR='$RUNTIME_CONTROL_TEST_ROOT/backups'
SERVICE_USER=nobody
SERVICE_GROUP='$nobody_group'
NODE_ENV=production
BIND_ADDRESS=127.0.0.1
APP_PORT=3000
RUNTIME_ENV_KEYS='SINGLE,FINAL'
SINGLE='one value'
FINAL='final value'
CONFIG
  printf 'root sentinel\n' > "$RUNTIME_CONTROL_TEST_ROOT/sentinel"
  chmod 0600 "$RUNTIME_CONTROL_TEST_ROOT/sentinel"
  sentinel_metadata="$(stat -c '%u:%g:%Y' "$RUNTIME_CONTROL_TEST_ROOT/sentinel")"
  chown nobody:"$nobody_group" "$RUNTIME_CONTROL_TEST_ROOT/logs"
  ln -s "$RUNTIME_CONTROL_TEST_ROOT/sentinel" "$RUNTIME_CONTROL_TEST_ROOT/logs/stdout.log"
  expect_failure bash -c 'source "$1" "$2"; prepare_runtime' _ "$RUNTIME_CONTROL_TEST_ROOT/scripts/linux/install-functions.sh" "$RUNTIME_CONTROL_TEST_ROOT/app.env"
  [[ "$(cat "$RUNTIME_CONTROL_TEST_ROOT/sentinel")" == 'root sentinel' && "$(stat -c '%u:%g:%Y' "$RUNTIME_CONTROL_TEST_ROOT/sentinel")" == "$sentinel_metadata" ]]
  rm "$RUNTIME_CONTROL_TEST_ROOT/logs/stdout.log"
  bash -c 'source "$1" "$2"; prepare_runtime; unset SINGLE FINAL; source "$ENV_FILE"; [[ "${SINGLE:-}" == "one value" && "${FINAL:-}" == "final value" ]]' _ "$RUNTIME_CONTROL_TEST_ROOT/scripts/linux/install-functions.sh" "$RUNTIME_CONTROL_TEST_ROOT/app.env"
  [[ "$(stat -c %u "$RUNTIME_CONTROL_TEST_ROOT/logs/stdout.log")" == "$nobody_uid" ]]
  [[ "$(stat -c %u "$RUNTIME_CONTROL_TEST_ROOT/logs/stderr.log")" == "$nobody_uid" ]]
  mkdir "$RUNTIME_CONTROL_TEST_ROOT/hardlinked-app"
  chmod 0755 "$RUNTIME_CONTROL_TEST_ROOT/hardlinked-app"
  ln "$RUNTIME_CONTROL_TEST_ROOT/sentinel" "$RUNTIME_CONTROL_TEST_ROOT/hardlinked-app/root-link"
  expect_failure bash -c 'source "$1" "$2"; APP_DIR="$3"; prepare_runtime' _ "$RUNTIME_CONTROL_TEST_ROOT/scripts/linux/install-functions.sh" "$RUNTIME_CONTROL_TEST_ROOT/app.env" "$RUNTIME_CONTROL_TEST_ROOT/hardlinked-app"
  [[ "$(stat -c %u "$RUNTIME_CONTROL_TEST_ROOT/sentinel")" == 0 && "$(stat -c %a "$RUNTIME_CONTROL_TEST_ROOT/hardlinked-app")" == 755 ]]
  echo 'Actual unprivileged log initialization rejected a root-file symlink; custom env keys and safe ownership transfer passed.'
else
  echo 'Actual privileged log-init/ownership fixture requires native Linux root and an existing nobody account.'
fi

hardening_prepare_control_directory "$TEST_ROOT/control/logs"
hardening_create_control_file "$TEST_ROOT/control/logs/healthcheck.log"
printf '%02048d\n' 0 > "$TEST_ROOT/control/logs/healthcheck.log"
hardening_rotate_log "$TEST_ROOT/control/logs/healthcheck.log" 1024 2
[[ -s "$TEST_ROOT/control/logs/healthcheck.log.1" && ! -s "$TEST_ROOT/control/logs/healthcheck.log" ]]
printf '%02048d\n' 0 > "$TEST_ROOT/control/logs/proxy.log"
proxy_inode="$(stat -c %i "$TEST_ROOT/control/logs/proxy.log" 2>/dev/null || stat -f %i "$TEST_ROOT/control/logs/proxy.log")"
hardening_copytruncate_control_log "$TEST_ROOT/control/logs/proxy.log" 1024 2
[[ -s "$TEST_ROOT/control/logs/proxy.log.1" && ! -s "$TEST_ROOT/control/logs/proxy.log" ]]
[[ "$proxy_inode" == "$(stat -c %i "$TEST_ROOT/control/logs/proxy.log" 2>/dev/null || stat -f %i "$TEST_ROOT/control/logs/proxy.log")" ]]
mkdir -p "$TEST_ROOT/untrusted"
chmod 0777 "$TEST_ROOT/untrusted"
untrusted_metadata="$(hardening_stat "$TEST_ROOT/untrusted")"
if [[ "${untrusted_metadata#* }" != 777 ]]; then
  # MSYS does not apply Unix directory modes. Exercise the decision with a
  # faithful metadata fixture, without claiming a native permission test.
  hardening_stat() {
    if [[ "$1" == "$TEST_ROOT/untrusted" ]]; then printf '%s 777\n' "$EUID";
    else stat -c '%u %a' -- "$1" 2>/dev/null || stat -f '%u %Lp' "$1" 2>/dev/null; fi
  }
  echo "Directory-mode rejection uses mocked metadata on this host."
fi
expect_failure hardening_prepare_control_directory "$TEST_ROOT/untrusted/control"
# shellcheck source=scripts/linux/runtime-hardening.sh
source "$REPO_ROOT/scripts/linux/runtime-hardening.sh"
chmod 0700 "$TEST_ROOT/untrusted"
printf 'sentinel\n' > "$TEST_ROOT/target"
if ln -s "$TEST_ROOT/target" "$TEST_ROOT/control/logs/link.log" 2>/dev/null && [[ -L "$TEST_ROOT/control/logs/link.log" ]]; then
  expect_failure hardening_create_control_file "$TEST_ROOT/control/logs/link.log"
  expect_failure hardening_copytruncate_control_log "$TEST_ROOT/control/logs/link.log" 1024 2
  [[ "$(cat "$TEST_ROOT/target")" == sentinel ]]
  mkdir "$TEST_ROOT/alias-target"
  ln -s "$TEST_ROOT/alias-target" "$TEST_ROOT/native-alias"
  hardening_prepare_control_directory "$TEST_ROOT/native-alias/control"
  [[ -d "$TEST_ROOT/alias-target/control" ]]
  expect_failure hardening_prepare_control_directory "$TEST_ROOT/native-alias"
  echo "Real symlink control-file rejection passed."
else
  echo "Real symlink test skipped: this host cannot create Unix symlinks."
fi

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/app-logs" "$TEST_ROOT/backups"
cat > "$TEST_ROOT/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MONITOR_TRACE"
case "$1" in
  is-active) [[ "${MOCK_SERVICE_ACTIVE:-true}" == true ]] ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'curl' >> "$MONITOR_TRACE"
printf '%s' "${MOCK_HTTP_CODE:-200}"
exit "${MOCK_HTTP_EXIT:-0}"
MOCK
chmod 0755 "$TEST_ROOT/bin/"*
cat > "$TEST_ROOT/app.env" <<CONFIG
APP_NAME='hardening-test'
SERVICE_MANAGER='systemd'
LOG_DIR='$TEST_ROOT/app-logs'
HEALTHCHECK_STATE_DIR='$TEST_ROOT/state'
DEPLOYMENT_LOCK_ROOT='$TEST_ROOT/locks'
DEPLOYMENT_TRANSACTION_ROOT='$TEST_ROOT/transactions'
BACKUP_DIR='$TEST_ROOT/backups'
HEALTH_URL='http://127.0.0.1:3000/health'
HEALTHCHECK_FAILURE_THRESHOLD='2'
HEALTHCHECK_RESTART_COOLDOWN='3600'
BACKUP_RETENTION_DAYS='90'
CONFIG
export MONITOR_TRACE="$TEST_ROOT/monitor-trace"
export PATH="$TEST_ROOT/bin:$PATH"
hardening_prepare_control_directory "$TEST_ROOT/locks"
hardening_prepare_control_directory "$TEST_ROOT/transactions"
mkdir "$TEST_ROOT/locks/hardening-test.lock"
bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
[[ ! -e "$MONITOR_TRACE" ]]
rmdir "$TEST_ROOT/locks/hardening-test.lock"
# A vanished mutex after a killed deploy must not permit recovery against a
# partially imported app, nor rotate/prune the evidence needed by an operator.
printf '%2048s\n' 'retained-monitor-log' > "$TEST_ROOT/state/logs/healthcheck.log"
cp "$TEST_ROOT/state/logs/healthcheck.log" "$TEST_ROOT/retained-monitor-log"
printf 'FAILURES=1\nLAST_RESTART=0\n' > "$TEST_ROOT/state/healthcheck.state"
cp "$TEST_ROOT/state/healthcheck.state" "$TEST_ROOT/retained-monitor-state"
mkdir "$TEST_ROOT/backups/app.19990101000000.999.bak"
printf "HEALTHCHECK_LOG_MAX_BYTES='1024'\n" >> "$TEST_ROOT/app.env"
for pending_case in legacy-managed legacy-package persistent-managed persistent-package; do
  pending_kind="${pending_case##*-}"
  pending_prefix="$TEST_ROOT/locks/hardening-test.lock"
  if [[ "$pending_case" == persistent-* ]]; then
    pending_prefix="$TEST_ROOT/transactions/hardening-test.lock"
    # Simulate a reboot losing the whole volatile mutex tree, while the journal
    # survives. The monitor will safely recreate only its volatile app mutex.
    mkdir "$TEST_ROOT/locks/hardening-test.lock"
    printf 'Token=%s\n' 'killed-deployment' > "$TEST_ROOT/locks/hardening-test.lock/owner"
    rm "$TEST_ROOT/locks/hardening-test.lock/owner"
    rmdir "$TEST_ROOT/locks/hardening-test.lock" "$TEST_ROOT/locks"
  fi
  if [[ "$pending_kind" == managed ]]; then
    pending_path="$pending_prefix.managed-transaction.killed"
    mkdir "$pending_path"
    printf 'manual-recovery-evidence\n' > "$pending_path/evidence"
  else
    pending_path="$pending_prefix.package-transaction.killed.state"
    printf 'manual-recovery-evidence\n' > "$pending_path"
  fi
  bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env" > "$TEST_ROOT/pending-monitor-output" 2>&1
  grep -q 'Health check deferred until unfinished deployment recovery' "$TEST_ROOT/pending-monitor-output"
  [[ ! -e "$MONITOR_TRACE" && ! -e "$TEST_ROOT/locks/hardening-test.lock" ]]
  cmp "$TEST_ROOT/retained-monitor-log" "$TEST_ROOT/state/logs/healthcheck.log"
  cmp "$TEST_ROOT/retained-monitor-state" "$TEST_ROOT/state/healthcheck.state"
  [[ -d "$TEST_ROOT/backups/app.19990101000000.999.bak" && ! -e "$TEST_ROOT/state/logs/healthcheck.log.1" ]]
  if [[ "$pending_kind" == managed ]]; then
    [[ "$(cat "$pending_path/evidence")" == manual-recovery-evidence ]]; rm -r -- "$pending_path"
  else
    [[ "$(cat "$pending_path")" == manual-recovery-evidence ]]; rm -- "$pending_path"
  fi
done
rm "$TEST_ROOT/state/healthcheck.state"
printf '' > "$TEST_ROOT/state/logs/healthcheck.log"
rm -r "$TEST_ROOT/backups/app.19990101000000.999.bak"
mkdir "$TEST_ROOT/backups/app.20000101000000.123.bak" "$TEST_ROOT/backups/unrelated"
printf 'old release\n' > "$TEST_ROOT/backups/app.20000101000000.123.bak/server.js"
fresh_backup="$TEST_ROOT/backups/app.$(date -u +%Y%m%d%H%M%S).456.bak"
mkdir "$fresh_backup"
touch -t 200001010000 "$fresh_backup"
printf 'active log\n' > "$TEST_ROOT/app-logs/stdout.log"
touch -t 200001010000 "$TEST_ROOT/app-logs/stdout.log"
bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
[[ ! -e "$TEST_ROOT/backups/app.20000101000000.123.bak" && -d "$fresh_backup" && -d "$TEST_ROOT/backups/unrelated" ]]
[[ -f "$TEST_ROOT/app-logs/stdout.log" && -f "$TEST_ROOT/state/logs/healthcheck.log" ]]
[[ ! -f "$TEST_ROOT/app-logs/healthcheck.log" ]]
export MOCK_SERVICE_ACTIVE=false
expect_failure bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
[[ "$(grep -c '^restart ' "$MONITOR_TRACE" || true)" == 0 ]]
expect_failure bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
expect_failure bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
expect_failure bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
[[ "$(grep -c '^restart ' "$MONITOR_TRACE")" == 1 ]]
[[ ! -e "$TEST_ROOT/locks/hardening-test.lock" ]]
unset MOCK_SERVICE_ACTIVE
export MOCK_HTTP_CODE=302
expect_failure bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$TEST_ROOT/app.env"
[[ "$(grep -c '^restart ' "$MONITOR_TRACE")" == 1 ]]
grep -q 'HTTP_FAILED.*status=302' "$TEST_ROOT/state/logs/healthcheck.log"
unset MOCK_HTTP_CODE

# Evaluate the actual rendered PID-control functions with mocked process and
# metadata commands. No real PID is ever signalled and no init script installed.
for template in sysv-node-app.init.tpl bsdrc-node-app.init.tpl; do
  (
    functions="$TEST_ROOT/$template.functions"
    if [[ "$template" == sysv* ]]; then sed '/^case "\$1" in/,$d' "$REPO_ROOT/templates/linux/$template" > "$functions";
    else sed '/^quote_shell()/,$d' "$REPO_ROOT/templates/linux/$template" > "$functions"; fi
    # shellcheck disable=SC1090
    source "$functions"
    PID_DIR="$TEST_ROOT/$template.pid"
    PID_FILE="$PID_DIR/app.pid"
    PID_IDENTITY_FILE="$PID_FILE.identity"
    mkdir "$PID_DIR"
    owner_result=0
    stat() { printf '%s 700\n' "$owner_result"; }
    current_identity='1000 Mon Jan 1 00:00:00 2024 node'
    current_title=node
    process_alive=true
    ps() {
      [[ "$process_alive" == true ]] || return 1
      case "$*" in
        *'-o comm='*) printf '%s\n' "$current_title" ;;
        *'-o lstart='*) printf '%s\n' "${current_identity% *}" ;;
        *) printf '%s\n' "${current_identity%% *}" ;;
      esac
    }
    kill() { printf '%s\n' "$*" >> "$TEST_ROOT/signals"; [[ "$1" == -0 ]] || process_alive=false; }
    printf '777\n' > "$PID_FILE"
    printf 'different process identity\n' > "$PID_IDENTITY_FILE"
    expect_failure is_running
    [[ ! -f "$TEST_ROOT/signals" ]]
    printf '%s\n' "$(process_identity)" > "$PID_IDENTITY_FILE"
    current_title=custom-node-process-title
    is_running
    current_identity='2000 Mon Jan 1 00:00:00 2024 node'
    expect_failure is_running
    current_identity='1000 Mon Jan 1 00:00:00 2024 node'
    rm "$TEST_ROOT/signals"
    printf '%s\n' '-1' > "$PID_FILE"
    expect_failure is_running
    [[ ! -f "$TEST_ROOT/signals" ]]
    printf '777\n' > "$PID_FILE"
    owner_result=1000
    expect_failure stop
    [[ ! -f "$TEST_ROOT/signals" ]]
    owner_result=0
    stop
    grep -Fxq -- 777 "$TEST_ROOT/signals"
    [[ ! -e "$PID_FILE" && ! -e "$PID_IDENTITY_FILE" ]]
    rm "$TEST_ROOT/signals"
  )
done

# Exercise the BSD native dispatch boundary. The rc.subr implementation and
# kernel command are fixtures, so this does not prove native lifecycle behavior.
cat > "$TEST_ROOT/rc.subr" <<'MOCK'
rc_cmd() { printf 'openbsd:%s:%s:%s\n' "$1" "$daemon" "$rc_usercheck" > "$BSD_DISPATCH_TRACE"; }
load_rc_config() { printf 'load:%s\n' "$1" > "$BSD_DISPATCH_TRACE"; }
run_rc_command() { printf 'action:%s:rcvar:%s:extra:%s\n' "$1" "$rcvar" "$extra_commands" >> "$BSD_DISPATCH_TRACE"; }
MOCK
cat > "$TEST_ROOT/bin/uname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_BSD_KERNEL"
MOCK
chmod 0755 "$TEST_ROOT/bin/uname"
sed -e 's/{{APP_NAME}}/7_example-app/g' -e 's/{{NODE_BIN}}/node/g' \
  -e "s#/etc/rc.d/rc.subr#$TEST_ROOT/rc.subr#g" -e "s#/etc/rc.subr#$TEST_ROOT/rc.subr#g" \
  "$REPO_ROOT/templates/linux/bsdrc-node-app.init.tpl" > "$TEST_ROOT/bsd-service.sh"
export BSD_DISPATCH_TRACE="$TEST_ROOT/bsd-dispatch"
MOCK_BSD_KERNEL=OpenBSD sh "$TEST_ROOT/bsd-service.sh" status
grep -Fxq 'openbsd:check:node:NO' "$BSD_DISPATCH_TRACE"
MOCK_BSD_KERNEL=FreeBSD sh "$TEST_ROOT/bsd-service.sh" onestart
grep -Fxq 'load:node_7_example_app' "$BSD_DISPATCH_TRACE"
grep -Fxq 'action:onestart:rcvar:node_7_example_app_enable:extra:status' "$BSD_DISPATCH_TRACE"
MOCK_BSD_KERNEL=NetBSD sh "$TEST_ROOT/bsd-service.sh" faststart
grep -Fxq 'action:faststart:rcvar:node_7_example_app:extra:status' "$BSD_DISPATCH_TRACE"
rm "$TEST_ROOT/bin/uname"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf '%02048d\n' 0 > "$TEST_ROOT/app-logs/stdout.log"
  old_inode="$(stat -c %i "$TEST_ROOT/app-logs/stdout.log" 2>/dev/null || stat -f %i "$TEST_ROOT/app-logs/stdout.log")"
  bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" --rotate-app-logs "$TEST_ROOT/app-logs" 1024 2
  new_inode="$(stat -c %i "$TEST_ROOT/app-logs/stdout.log" 2>/dev/null || stat -f %i "$TEST_ROOT/app-logs/stdout.log")"
  [[ "$old_inode" == "$new_inode" && ! -s "$TEST_ROOT/app-logs/stdout.log" && -s "$TEST_ROOT/app-logs/stdout.log.1" ]]
else
  expect_failure bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" --rotate-app-logs "$TEST_ROOT/app-logs" 1024 2
  echo "Root app-log rotation rejected; native service-user execution requires host integration."
fi

# BSD recovery restores app-scoped assignments/membership, preserving edits to
# unrelated services made after the deployment began. No host rc.conf is read.
# shellcheck source=scripts/linux/deployment-transaction.sh
source "$REPO_ROOT/scripts/linux/deployment-transaction.sh"
transaction_begin "$TEST_ROOT/bsd.managed-transaction.fixture"
export APP_NAME=hardening_test
rc_file="$TEST_ROOT/rc.conf"
printf 'other_enable="YES"\nhardening_test_enable="NO"\n' > "$rc_file"
transaction_record_rc_setting "$rc_file" hardening_test_enable
printf 'other_enable="NO"\nhardening_test_enable="YES"\nnew_enable="YES"\n' > "$rc_file"
openbsd_file="$TEST_ROOT/rc.conf.local"
printf 'pkg_scripts="other initially_enabled"\nunrelated="before"\n' > "$openbsd_file"
transaction_record_rc_setting "$openbsd_file" pkg_scripts
printf 'pkg_scripts="other initially_enabled hardening_test concurrently_added"\nunrelated="after"\n' > "$openbsd_file"
transaction_restore_rc_settings
grep -Fxq 'hardening_test_enable="NO"' "$rc_file"
grep -Fxq 'other_enable="NO"' "$rc_file"
grep -Fxq 'new_enable="YES"' "$rc_file"
grep -Fxq 'pkg_scripts="other initially_enabled concurrently_added"' "$openbsd_file"
grep -Fxq 'unrelated="after"' "$openbsd_file"
transaction_finish
transaction_begin "$TEST_ROOT/bsd-enabled.managed-transaction.fixture"
printf 'pkg_scripts=other hardening_test\n' > "$openbsd_file"
transaction_record_rc_setting "$openbsd_file" pkg_scripts
printf 'pkg_scripts="other concurrently_added"\n' > "$openbsd_file"
transaction_restore_rc_settings
grep -Fxq 'pkg_scripts="other concurrently_added hardening_test"' "$openbsd_file"
transaction_finish
printf 'pkg_scripts="$(touch forbidden)"\n' > "$openbsd_file"
expect_failure transaction_rc_pkg_scripts "$openbsd_file"
[[ ! -e forbidden ]]
# Registration restoration preserves unrelated services. MSYS copy emulation
# cannot establish native symlink semantics, so that host reports a skip.
mkdir -p "$TEST_ROOT/registration"/{rc2.d,rc3.d,runlevels/default,runlevels/boot,units/multi-user.target.wants,units/custom.target.requires}
printf 'service\n' > "$TEST_ROOT/registration/service"
if ln -s ../service "$TEST_ROOT/registration/rc2.d/S20hardening_test" && [[ -L "$TEST_ROOT/registration/rc2.d/S20hardening_test" ]]; then
  transaction_begin "$TEST_ROOT/registration.managed-transaction.fixture"
  transaction_record_registration "$TEST_ROOT/registration" sysv hardening_test
  ln -s ../../service "$TEST_ROOT/registration/runlevels/boot/hardening_test"
  transaction_record_registration "$TEST_ROOT/registration" openrc hardening_test
  ln -s ../../service "$TEST_ROOT/registration/units/custom.target.requires/hardening_test.service"
  transaction_record_registration "$TEST_ROOT/registration/units" systemd hardening_test.service
  rm "$TEST_ROOT/registration/rc2.d/S20hardening_test" "$TEST_ROOT/registration/runlevels/boot/hardening_test" "$TEST_ROOT/registration/units/custom.target.requires/hardening_test.service"
  ln -s ../service "$TEST_ROOT/registration/rc3.d/S99hardening_test"
  ln -s ../service "$TEST_ROOT/registration/rc3.d/S99unrelated"
  ln -s ../../service "$TEST_ROOT/registration/runlevels/default/hardening_test"
  ln -s ../../service "$TEST_ROOT/registration/runlevels/default/unrelated"
  ln -s ../../service "$TEST_ROOT/registration/units/multi-user.target.wants/hardening_test.service"
  ln -s ../../service "$TEST_ROOT/registration/units/multi-user.target.wants/unrelated.service"
  transaction_restore_registration
  [[ -L "$TEST_ROOT/registration/rc2.d/S20hardening_test" && ! -L "$TEST_ROOT/registration/rc3.d/S99hardening_test" && -L "$TEST_ROOT/registration/rc3.d/S99unrelated" ]]
  [[ -L "$TEST_ROOT/registration/runlevels/boot/hardening_test" && ! -L "$TEST_ROOT/registration/runlevels/default/hardening_test" && -L "$TEST_ROOT/registration/runlevels/default/unrelated" ]]
  [[ -L "$TEST_ROOT/registration/units/custom.target.requires/hardening_test.service" && ! -L "$TEST_ROOT/registration/units/multi-user.target.wants/hardening_test.service" && -L "$TEST_ROOT/registration/units/multi-user.target.wants/unrelated.service" ]]
  transaction_finish
else
  echo 'Native SysV/OpenRC/systemd registration-link restoration skipped: Unix symlinks unavailable.'
fi
if [[ "$(uname -s)" == Linux ]]; then
  # Actual native registration starts at /etc; a nested fixture alone misses
  # the distinction between a trusted directory and a managed file's parent.
  registration_app="nodekit-root-registration-$$-$RANDOM"
  transaction_begin "$TEST_ROOT/native-root.managed-transaction.fixture"
  transaction_record_registration /etc sysv "$registration_app"
  transaction_record_registration /etc openrc "$registration_app"
  transaction_restore_registration
  expect_failure transaction_record_registration / sysv "$registration_app"
  transaction_finish
fi

echo "Unix hardening behavioral checks passed."
