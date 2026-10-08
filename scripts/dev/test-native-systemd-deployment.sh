#!/usr/bin/env bash
# Explicit native-host integration drill. Never run as part of portable fixtures.
# Arguments: directory containing verified-archive.txt, SHASUMS256.txt, Node24
# archive, and the exact-version official Debian curl archive; evidence directory.
set -Eeuo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Run this isolated native systemd drill as root.' >&2; exit 1; }
[[ "$(ps -p 1 -o comm=)" == systemd ]] || { echo 'A native running systemd host is required.' >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
artifacts="$(realpath "${1:?Verified artifact directory required.}")"
evidence="$(realpath "${2:?Existing evidence directory required.}")"
[[ "$artifacts" == "$REPO_ROOT/.tmp/"* && "$evidence" == "$REPO_ROOT/.tmp/"* ]] || exit 1
exec > >(tee "$evidence/execution.log") 2>&1
nonce="$(tr -d '-' < /proc/sys/kernel/random/uuid)"
app="ndkproof-${nonce:0:12}"
account="ndkproof_${nonce:0:12}"
tree="/var/lib/node-deploy-kit-native-proof.$nonce"
[[ "$tree" == /var/lib/node-deploy-kit-native-proof.* && ! -e "$tree" ]] || exit 1
for unit in "$app.service" "$app-healthcheck.service" "$app-healthcheck.timer"; do
  [[ ! -e "/etc/systemd/system/$unit" && ! -L "/etc/systemd/system/$unit" ]] || exit 1
  [[ "$(systemctl show "$unit" --property=LoadState --value)" == not-found ]] || exit 1
done
! getent passwd "$account" >/dev/null || exit 1
! getent group "$account" >/dev/null || exit 1
for path in "/usr/local/sbin/$app-healthcheck.sh" "/usr/local/sbin/$app-healthcheck-hardening.sh" "/etc/node-enterprise-deploy-kit/$app.env"; do
  [[ ! -e "$path" && ! -L "$path" ]] || exit 1
done
control_parent_existed=false
control_parent_mode=''
if [[ -d /etc/node-enterprise-deploy-kit ]]; then
  control_parent_existed=true
  control_parent_mode="$(stat -c %a /etc/node-enterprise-deploy-kit)"
fi
mkdir -m 0755 "$tree"
printf '%s\n' "$nonce" > "$tree/.owned-native-proof"
holder_pid=''
cleanup() {
  local result=$? cleanup_failed=false
  trap - EXIT ERR
  [[ -z "$holder_pid" ]] || { touch "$tree/release-holder"; wait "$holder_pid" || true; }
  journalctl -u "$app.service" -u "$app-healthcheck.service" --no-pager > "$evidence/journal.txt" 2>&1 || true
  systemctl show "$app.service" --no-pager > "$evidence/service-state.txt" 2>&1 || true
  cp -a "$tree/control" "$evidence/last-control" 2>/dev/null || true
  systemctl disable --now "$app-healthcheck.timer" "$app.service" >/dev/null 2>&1 || true
  systemctl stop "$app-healthcheck.service" >/dev/null 2>&1 || true
  for unit in "$app.service" "$app-healthcheck.service" "$app-healthcheck.timer"; do
    rm -f -- "/etc/systemd/system/$unit"
  done
  rm -f -- "/usr/local/sbin/$app-healthcheck.sh" "/usr/local/sbin/$app-healthcheck-hardening.sh" "/etc/node-enterprise-deploy-kit/$app.env"
  systemctl daemon-reload
  systemctl reset-failed "$app.service" "$app-healthcheck.service" "$app-healthcheck.timer" >/dev/null 2>&1 || true
  if getent passwd "$account" >/dev/null; then
    [[ "$(getent passwd "$account" | cut -d: -f6)" == "$tree/app" ]] && userdel "$account" || cleanup_failed=true
  fi
  if getent group "$account" >/dev/null; then groupdel "$account" || cleanup_failed=true; fi
  if [[ "$control_parent_existed" == true ]]; then chmod "$control_parent_mode" /etc/node-enterprise-deploy-kit
  else rmdir /etc/node-enterprise-deploy-kit 2>/dev/null || true; fi
  [[ "$(realpath "$tree")" == "/var/lib/node-deploy-kit-native-proof.$nonce" && "$(cat "$tree/.owned-native-proof")" == "$nonce" ]] || { echo 'Refusing unsafe native fixture cleanup.' >&2; exit 1; }
  rm -rf -- "$tree"
  for unit in "$app.service" "$app-healthcheck.service" "$app-healthcheck.timer"; do
    [[ "$(systemctl show "$unit" --property=LoadState --value)" == not-found ]] || cleanup_failed=true
  done
  ! getent passwd "$account" >/dev/null || cleanup_failed=true
  ! getent group "$account" >/dev/null || cleanup_failed=true
  if [[ "$cleanup_failed" == true ]]; then echo 'Native cleanup verification FAILED.' >&2; exit 1; fi
  printf 'Native cleanup verified: %s, account %s, root tree %s removed.\n' "$app" "$account" "$tree"
  exit "$result"
}
trap cleanup EXIT
trap 'echo "Native proof failure at line $LINENO" >&2' ERR
archive="$(sed -n '1p' "$artifacts/verified-archive.txt")"
archive_sha="$(sed -n '2p' "$artifacts/verified-archive.txt")"
[[ "$archive" =~ ^node-v24\.[0-9]+\.[0-9]+-linux-x64\.tar\.gz$ && "$archive_sha" =~ ^[a-f0-9]{64}$ ]] || exit 1
grep -Fxq "$archive_sha  $archive" "$artifacts/SHASUMS256.txt"
printf '%s  %s\n' "$archive_sha" "$artifacts/$archive" | sha256sum -c -
printf '%s  %s\n' ebb7e0cbe30ad23bce0d28a848ccfeb9b73b82817eb4fe12fa20d2845f62dc73 "$artifacts/curl_8.14.1-2+deb13u5_amd64.deb" | sha256sum -c -
[[ "$(dpkg-query -W -f='${Version}' libcurl4t64:amd64)" == 8.14.1-2+deb13u5 ]] || { echo 'Exact curl/libcurl ABI mismatch.' >&2; exit 1; }
mkdir "$tree/node" "$tree/curl" "$tree/app" "$tree/control"
chmod 0700 "$tree/control"
tar -xzf "$artifacts/$archive" --strip-components=1 -C "$tree/node"
dpkg-deb -x "$artifacts/curl_8.14.1-2+deb13u5_amd64.deb" "$tree/curl"
export PATH="$tree/curl/usr/bin:$tree/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
node --version
curl --version | head -1
port="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
cat > "$tree/app/server.js" <<'JS'
const http = require('http');
http.createServer((req, res) => {
  res.statusCode = req.url === '/unhealthy' ? 503 : 200;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ generation: process.env.RUNTIME_TOKEN, uid: process.getuid(), pid: process.pid }));
}).listen(Number(process.env.PORT), '127.0.0.1');
JS
config="$tree/control/app.env"
cat > "$config" <<EOF
APP_NAME='$app'
APP_DISPLAY_NAME='Isolated native deployment proof'
APP_DESCRIPTION='Temporary production safety regression'
APP_RUNTIME=node
APP_FRAMEWORK=node
DEPLOYMENT_MODE=reverse_proxy
SERVICE_MANAGER=systemd
REVERSE_PROXY=none
APP_DIR='$tree/app'
NODE_BIN='$tree/node/bin/node'
START_SCRIPT=server.js
NODE_ARGUMENTS=''
SERVICE_USER='$account'
SERVICE_GROUP='$account'
LOG_DIR='$tree/logs'
ENV_FILE='$tree/control/runtime.env'
BACKUP_DIR='$tree/backups'
HEALTHCHECK_STATE_DIR='$tree/health-state'
DEPLOYMENT_LOCK_ROOT='$tree/locks'
DEPLOYMENT_TRANSACTION_ROOT='$tree/transactions'
SHARED_CONTROL_LOCK_ROOT='$tree/locks'
APP_PORT='$port'
BIND_ADDRESS=127.0.0.1
NODE_ENV=production
HEALTH_URL='http://127.0.0.1:$port/health'
RUNTIME_ENV_KEYS=RUNTIME_TOKEN
RUNTIME_TOKEN=native-v1
INSTALL_COMMAND=''
BUILD_COMMAND=''
SKIP_INSTALL=true
SKIP_BUILD=true
SKIP_PACKAGE_IMPORT=true
SKIP_REVERSE_PROXY=false
SKIP_HEALTH_CHECK=false
ALLOW_PORT_IN_USE=true
HEALTHCHECK_INTERVAL=3600
HEALTHCHECK_FAILURE_THRESHOLD=1
HEALTHCHECK_RESTART_COOLDOWN=300
HEALTHCHECK_TIMEOUT=3
POST_DEPLOY_HEALTH_ATTEMPTS=8
POST_DEPLOY_HEALTH_DELAY_SECONDS=1
REQUIRE_POST_DEPLOY_HEALTH_CHECK=true
FAILURE_RESTART_DELAY=1
PATH='$PATH'
EOF
chmod 0600 "$config"
assert_body() {
  local generation="$1" body
  body="$(curl --fail --silent "http://127.0.0.1:$port/health")"
  printf 'Real native HTTP response: %s\n' "$body"
  node -e 'const b=JSON.parse(process.argv[1]);if(b.generation!==process.argv[2]||b.uid===0)process.exit(1)' "$body" "$generation"
}
wait_active() {
  local i
  for i in $(seq 1 60); do
    if systemctl is-active --quiet "$app" && curl --fail --silent "http://127.0.0.1:$port/health" >/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
echo 'Native systemd initial install and privileged-control permissions'
bash "$REPO_ROOT/deploy.sh" "$config"
assert_body native-v1
systemctl is-enabled --quiet "$app"
systemctl is-active --quiet "$app-healthcheck.timer"
[[ "$(stat -c '%u %a' "$tree/control/runtime.env")" == '0 640' ]]
[[ "$(stat -c '%u %a' "/etc/node-enterprise-deploy-kit/$app.env")" == '0 640' ]]
[[ "$(stat -c '%u %a' "$tree/health-state")" == '0 700' ]]
[[ "$(systemctl show "$app" --property=NoNewPrivileges --value)" == yes ]]
[[ "$(systemctl show "$app" --property=ProtectSystem --value)" == full ]]
echo 'Native idempotent redeploy and runtime environment update'
bash "$REPO_ROOT/deploy.sh" "$config"
assert_body native-v1
sed -i 's/RUNTIME_TOKEN=native-v1/RUNTIME_TOKEN=native-v2/' "$config"
bash "$REPO_ROOT/deploy.sh" "$config"
assert_body native-v2
systemctl stop "$app-healthcheck.timer"
unit_hash="$(sha256sum "/etc/systemd/system/$app.service" | cut -d' ' -f1)"
env_hash="$(sha256sum "$tree/control/runtime.env" | cut -d' ' -f1)"
monitor_hash="$(sha256sum "/etc/node-enterprise-deploy-kit/$app.env" | cut -d' ' -f1)"
bad_config="$tree/control/bad.env"
runtime_replacement='bad-replacement'
sed -e "s/RUNTIME_TOKEN=native-v2/RUNTIME_TOKEN=$runtime_replacement/" -e "s|:$port/health|:$port/unhealthy|" "$config" > "$bad_config"
echo 'Native downstream HTTP failure restores old config, enablement, running process and old HTTP health'
if bash "$REPO_ROOT/deploy.sh" "$bad_config"; then echo 'Unhealthy deployment was incorrectly accepted.' >&2; exit 1; fi
assert_body native-v2
[[ "$(sha256sum "/etc/systemd/system/$app.service" | cut -d' ' -f1)" == "$unit_hash" ]]
[[ "$(sha256sum "$tree/control/runtime.env" | cut -d' ' -f1)" == "$env_hash" ]]
[[ "$(sha256sum "/etc/node-enterprise-deploy-kit/$app.env" | cut -d' ' -f1)" == "$monitor_hash" ]]
systemctl is-enabled --quiet "$app"
echo 'Native monitor and concurrent deployment respect the same app mutex'
bash -c 'source "$1/scripts/linux/common.sh"; load_config_file CONFIG_FILE "$1" "$2"; source "$1/scripts/linux/deployment-lock.sh"; deployment_lock_acquire "$APP_NAME"; trap deployment_lock_release EXIT; touch "$3/holder-ready"; for i in $(seq 1 300); do [[ ! -f "$3/release-holder" ]] || exit 0; sleep 0.1; done; exit 1' _ "$REPO_ROOT" "$config" "$tree" &
holder_pid=$!
for ((i=0; i<60; i++)); do [[ ! -f "$tree/holder-ready" ]] || break; sleep 0.1; done
[[ -f "$tree/holder-ready" ]]
old_pid="$(systemctl show "$app" --property=MainPID --value)"
deferred="$(bash "/usr/local/sbin/$app-healthcheck.sh" "/etc/node-enterprise-deploy-kit/$app.env")"
[[ "$deferred" == *'deferred while another operation holds the application lock'* ]]
if bash "$REPO_ROOT/deploy.sh" "$config"; then echo 'Concurrent deployment escaped the mutex.' >&2; exit 1; fi
[[ "$(systemctl show "$app" --property=MainPID --value)" == "$old_pid" ]]
touch "$tree/release-holder"
wait "$holder_pid"
holder_pid=''
echo 'Native service crash restart, scheduled monitor stopped-service restart, and persistent cooldown'
old_pid="$(systemctl show "$app" --property=MainPID --value)"
[[ "$old_pid" =~ ^[1-9][0-9]*$ && "$(readlink -f "/proc/$old_pid/exe")" == "$tree/node/bin/node" && "$(readlink -f "/proc/$old_pid/cwd")" == "$tree/app" ]]
kill -KILL "$old_pid"
wait_active
[[ "$(systemctl show "$app" --property=MainPID --value)" != "$old_pid" ]]
systemctl stop "$app"
systemctl start "$app-healthcheck.service" >/dev/null 2>&1 || true
wait_active
grep -q '^LAST_RESTART_EPOCH=[1-9]' "$tree/health-state/healthcheck.state"
systemctl stop "$app"
systemctl start "$app-healthcheck.service" >/dev/null 2>&1 || true
[[ "$(systemctl show "$app" --property=ActiveState --value)" == inactive ]]
grep -q 'RESTART_SUPPRESSED_COOLDOWN' "$tree/health-state/logs/healthcheck.log"
systemctl start "$app"
wait_active
assert_body native-v2
systemctl start "$app-healthcheck.service"
systemctl start "$app-healthcheck.timer"
echo 'Native persistent recovery guard survives loss of volatile mutex state'
systemctl stop "$app-healthcheck.timer"
systemctl stop "$app-healthcheck.service"
old_pid="$(systemctl show "$app" --property=MainPID --value)"
monitor_state_hash="$(sha256sum "$tree/health-state/healthcheck.state" | cut -d' ' -f1)"
monitor_log_hash="$(sha256sum "$tree/health-state/logs/healthcheck.log" | cut -d' ' -f1)"
pending="$tree/transactions/$app.lock.managed-transaction.synthetic-killed"
mkdir -m 0700 "$pending"
printf 'manual-recovery-evidence\n' > "$pending/evidence"
rmdir "$tree/locks"
deferred="$(bash "/usr/local/sbin/$app-healthcheck.sh" "/etc/node-enterprise-deploy-kit/$app.env" 2>&1)"
printf 'Native recovery-guard monitor response: %s\n' "$deferred"
[[ "$deferred" == *'deferred until unfinished deployment recovery'* ]]
if bash "$REPO_ROOT/deploy.sh" "$config"; then echo 'Retained journal did not block a new native deployment.' >&2; exit 1; fi
[[ "$(systemctl show "$app" --property=MainPID --value)" == "$old_pid" ]]
[[ "$(sha256sum "$tree/health-state/healthcheck.state" | cut -d' ' -f1)" == "$monitor_state_hash" ]]
[[ "$(sha256sum "$tree/health-state/logs/healthcheck.log" | cut -d' ' -f1)" == "$monitor_log_hash" ]]
[[ "$(cat "$pending/evidence")" == manual-recovery-evidence && ! -e "$tree/locks/$app.lock" ]]
rm "$pending/evidence"
rmdir "$pending"
assert_body native-v2
systemctl start "$app-healthcheck.timer"
bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$config" --fail-on-critical --json-output "$evidence/status.json"
systemctl show "$app" --property=User --property=Group --property=NoNewPrivileges --property=PrivateTmp --property=ProtectSystem --property=ProtectHome --property=Restart --property=RestartUSec > "$evidence/hardening.txt"
echo 'Native kit uninstall drains scheduler and removes service/control registrations'
bash "$REPO_ROOT/scripts/linux/uninstall-node-service.sh" "$config"
for unit in "$app.service" "$app-healthcheck.service" "$app-healthcheck.timer"; do
  [[ "$(systemctl show "$unit" --property=LoadState --value)" == not-found ]]
  [[ "$(systemctl show "$unit" --property=ActiveState --value)" == inactive ]]
done
for path in "/usr/local/sbin/$app-healthcheck.sh" "/usr/local/sbin/$app-healthcheck-hardening.sh" "/etc/node-enterprise-deploy-kit/$app.env"; do
  [[ ! -e "$path" && ! -L "$path" ]]
done
[[ -d "$tree/app" && -d "$tree/logs" ]]
printf 'PASS: native systemd install, update, failed health rollback, app mutex, persistent journal deferral after lost volatile locks, automatic crash recovery, real scheduled monitor recovery and cooldown, and actual kit uninstall.\n' | tee "$evidence/result.txt"
