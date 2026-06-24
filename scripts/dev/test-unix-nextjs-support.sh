#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$REPO_ROOT/.tmp/unix-nextjs-support-$$"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT"

# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$*" > "$path"
}

new_standalone_layout() {
  local app_dir="$1"
  mkdir -p "$app_dir/.next/static" "$app_dir/node_modules"
  write_file "$app_dir/server.js" "console.log('standalone');"
  write_file "$app_dir/.next/static/app.js" "console.log('static');"
  write_file "$app_dir/.next/BUILD_ID" "example-build"
}

new_next_start_layout() {
  local app_dir="$1"
  mkdir -p "$app_dir/.next" "$app_dir/node_modules/next/dist/bin"
  write_file "$app_dir/package.json" '{"scripts":{"start":"next start"},"dependencies":{"next":"0.0.0-test"}}'
  write_file "$app_dir/.next/BUILD_ID" "example-build"
  write_file "$app_dir/node_modules/next/dist/bin/next" "#!/usr/bin/env node"
}

new_next_project_layout() {
  local project_dir="$1"
  mkdir -p "$project_dir/.next/standalone/node_modules" "$project_dir/.next/static" "$project_dir/public"
  write_file "$project_dir/.next/standalone/server.js" "console.log('standalone');"
  write_file "$project_dir/.next/standalone/package.json" '{"scripts":{"start":"node server.js"}}'
  write_file "$project_dir/.next/static/app.js" "console.log('static');"
  write_file "$project_dir/.next/BUILD_ID" "example-build"
  write_file "$project_dir/public/robots.txt" "User-agent: *"
}

write_env() {
  local path="$1" root="$2" port="$3" mode="${4:-standalone}" start_script="${5:-server.js}" service_manager="${6:-launchd}" node_arguments="${7:-}"
  if [[ "$mode" == "next-start" && -z "$node_arguments" ]]; then
    node_arguments="start -H 127.0.0.1"
  fi
  cat > "$path" <<EOF
APP_NAME="example-next-smoke"
APP_DISPLAY_NAME="Example Next Smoke"
APP_RUNTIME="node"
APP_FRAMEWORK="nextjs"
NEXTJS_DEPLOYMENT_MODE="$mode"
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
DEPLOYMENT_ID="example-deploy-001"
APP_DIR="$root/app"
NODE_BIN="/bin/sh"
START_SCRIPT="$start_script"
NODE_ARGUMENTS="$node_arguments"
APP_PORT="$port"
BIND_ADDRESS="127.0.0.1"
HEALTH_URL="http://127.0.0.1:$port/health"
LOG_DIR="$root/logs"
SERVICE_MANAGER="$service_manager"
REVERSE_PROXY="none"
SERVICE_USER="$(id -un)"
SERVICE_GROUP="$(id -gn)"
ENV_FILE="$root/etc/example-next-smoke.env"
HEALTHCHECK_STATE_DIR="$root/state"
EOF
}

expect_success() {
  local label="$1"
  shift
  if ! "$@"; then
    echo "$label failed unexpectedly." >&2
    exit 1
  fi
}

expect_failure() {
  local label="$1" expected="$2"
  shift 2
  local output exit_code
  set +e
  output="$("$@" 2>&1)"
  exit_code=$?
  set -e
  if [[ "$exit_code" -eq 0 ]]; then
    echo "$label succeeded unexpectedly." >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "$label failed, but did not contain expected text: $expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1" expected="$2"
  if ! grep -Fq "$expected" "$path"; then
    echo "$path is missing expected text: $expected" >&2
    printf '%s\n' "--- $path ---" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1" unexpected="$2"
  if grep -Fq "$unexpected" "$path"; then
    echo "$path contains unexpected text: $unexpected" >&2
    printf '%s\n' "--- $path ---" >&2
    cat "$path" >&2
    exit 1
  fi
}

render_node_service_template() {
  local template="$1" output="$2"
  BACKUP_DIR="$TEST_ROOT/backups" render_template_file "$template" "$output" \
    APP_NAME "example-next-smoke" \
    APP_DISPLAY_NAME "Example Next Smoke" \
    APP_DESCRIPTION "Example Next Smoke" \
    SERVICE_USER "$(id -un)" \
    SERVICE_GROUP "$(id -gn)" \
    APP_DIR "$TEST_ROOT/rendered/app" \
    ENV_FILE "$TEST_ROOT/rendered/etc/example-next-smoke.env" \
    NODE_BIN "/bin/sh" \
    START_SCRIPT "node_modules/next/dist/bin/next" \
    NODE_ARGUMENTS "start -H 127.0.0.1" \
    FAILURE_RESTART_DELAY "60" \
    LOG_DIR "$TEST_ROOT/rendered/logs" \
    RUNNER_SCRIPT "$TEST_ROOT/rendered/example-next-smoke-runner.sh"
}

test_env_assignment_quoting() {
  local env_file="$TEST_ROOT/env-quoting/runtime.env"
  mkdir -p "$(dirname "$env_file")"
  write_shell_env_assignment "$env_file" "APP_NAME" "example-next-smoke"
  write_shell_env_assignment "$env_file" "HOSTNAME" "127.0.0.1"
  write_shell_env_assignment "$env_file" "EXAMPLE_VALUE" "value with spaces and 'quotes'"
  expect_success "runtime env POSIX sh source" /bin/sh -c ". '$env_file'; [ \"\$EXAMPLE_VALUE\" = \"value with spaces and 'quotes'\" ]"
  expect_success "runtime env bash source" bash -c ". '$env_file'; [[ \"\$EXAMPLE_VALUE\" == \"value with spaces and 'quotes'\" ]]"
}

test_service_template_rendering() {
  local rendered="$TEST_ROOT/rendered"
  mkdir -p "$rendered"

  render_node_service_template "$REPO_ROOT/templates/linux/systemd-node-app.service.tpl" "$rendered/example-next-smoke.service"
  render_node_service_template "$REPO_ROOT/templates/linux/sysv-node-app.init.tpl" "$rendered/example-next-smoke.sysv"
  render_node_service_template "$REPO_ROOT/templates/linux/openrc-node-app.init.tpl" "$rendered/example-next-smoke.openrc"
  render_node_service_template "$REPO_ROOT/templates/linux/launchd-runner.sh.tpl" "$rendered/example-next-smoke-runner.sh"
  render_node_service_template "$REPO_ROOT/templates/linux/launchd-node-app.plist.tpl" "$rendered/example-next-smoke.plist"
  render_node_service_template "$REPO_ROOT/templates/linux/bsdrc-node-app.init.tpl" "$rendered/example-next-smoke.bsdrc"

  assert_contains "$rendered/example-next-smoke.service" "EnvironmentFile=-$TEST_ROOT/rendered/etc/example-next-smoke.env"
  assert_contains "$rendered/example-next-smoke.service" "ExecStart=/bin/sh node_modules/next/dist/bin/next start -H 127.0.0.1"

  assert_contains "$rendered/example-next-smoke.sysv" "ENV_FILE=\"$TEST_ROOT/rendered/etc/example-next-smoke.env\""
  assert_contains "$rendered/example-next-smoke.sysv" "START_SCRIPT=\"node_modules/next/dist/bin/next\""
  assert_contains "$rendered/example-next-smoke.sysv" "NODE_ARGUMENTS=\"start -H 127.0.0.1\""

  assert_contains "$rendered/example-next-smoke.openrc" "command_args=\"node_modules/next/dist/bin/next start -H 127.0.0.1\""
  assert_contains "$rendered/example-next-smoke.openrc" ". \"$TEST_ROOT/rendered/etc/example-next-smoke.env\""

  assert_contains "$rendered/example-next-smoke-runner.sh" "source \"$TEST_ROOT/rendered/etc/example-next-smoke.env\""
  assert_contains "$rendered/example-next-smoke-runner.sh" "exec \"/bin/sh\" \"node_modules/next/dist/bin/next\" start -H 127.0.0.1"
  assert_contains "$rendered/example-next-smoke.plist" "<string>$TEST_ROOT/rendered/example-next-smoke-runner.sh</string>"

  assert_contains "$rendered/example-next-smoke.bsdrc" "ENV_FILE=\"$TEST_ROOT/rendered/etc/example-next-smoke.env\""
  assert_contains "$rendered/example-next-smoke.bsdrc" "START_SCRIPT=\"node_modules/next/dist/bin/next\""
  assert_contains "$rendered/example-next-smoke.bsdrc" "NODE_ARGUMENTS=\"start -H 127.0.0.1\""

  expect_success "rendered launchd runner syntax" bash -n "$rendered/example-next-smoke-runner.sh"
  expect_success "rendered sysv syntax" /bin/sh -n "$rendered/example-next-smoke.sysv"
  expect_success "rendered openrc syntax" /bin/sh -n "$rendered/example-next-smoke.openrc"
  expect_success "rendered bsdrc syntax" /bin/sh -n "$rendered/example-next-smoke.bsdrc"
}

test_node_runtime_smoke() {
  local node_cmd="${NODE_BIN:-}"
  if [[ -z "$node_cmd" ]]; then
    node_cmd="$(command -v node 2>/dev/null || true)"
  fi
  if [[ -z "$node_cmd" ]]; then
    node_cmd="$(command -v node.exe 2>/dev/null || true)"
  fi
  if [[ -z "$node_cmd" ]]; then
    echo "Node.js was not found; skipping Unix Next.js runtime smoke."
    return
  fi
  if [[ "$(uname -s 2>/dev/null || true)" == "Linux" && "$node_cmd" == *.exe ]]; then
    echo "Windows node.exe under Linux/WSL does not preserve Unix inline env reliably; skipping Unix Next.js runtime smoke."
    return
  fi
  local port
  port="$("$node_cmd" -e "const net=require('net'); const s=net.createServer(); s.listen(0,'127.0.0.1',()=>{ console.log(s.address().port); s.close(); });")"
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
    echo "Could not allocate a free loopback port for Unix runtime smoke." >&2
    exit 1
  fi
  local runtime_root="$TEST_ROOT/runtime-smoke"
  local app_dir="$runtime_root/app"
  local pid=""
  mkdir -p "$app_dir/.next/static" "$app_dir/node_modules"
  write_file "$app_dir/.next/static/app.js" "console.log('static');"
  cat > "$app_dir/server.js" <<'NODE'
const http = require('http');
const host = process.env.HOSTNAME || process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || process.env.APP_PORT || 3000);
const appName = process.env.APP_NAME || 'unknown-app';
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      appName,
      envPort: process.env.PORT || '',
      envHostname: process.env.HOSTNAME || ''
    }));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('ok');
});
server.listen(port, host, () => console.log(`listening ${host}:${port}`));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
NODE
  cat > "$runtime_root/health-client.js" <<'NODE'
const http = require('http');

const url = process.argv[2];
const request = http.get(url, (response) => {
  let body = '';
  response.setEncoding('utf8');
  response.on('data', (chunk) => { body += chunk; });
  response.on('end', () => {
    if (response.statusCode !== 200) {
      process.stderr.write(`HTTP ${response.statusCode}\n${body}`);
      process.exit(2);
    }
    process.stdout.write(body);
  });
});

request.on('error', () => process.exit(1));
request.setTimeout(1500, () => {
  request.destroy();
  process.exit(3);
});
NODE

  (
    cd "$app_dir"
    NODE_ENV="production" \
      PORT="$port" \
      APP_PORT="$port" \
      APP_NAME="example-next-runtime-smoke" \
      BIND_ADDRESS="127.0.0.1" \
      HOST="127.0.0.1" \
      HOSTNAME="127.0.0.1" \
      "$node_cmd" server.js > "$runtime_root/stdout.log" 2> "$runtime_root/stderr.log"
  ) &
  pid="$!"

  local deadline=$((SECONDS + 15))
  local body=""
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Unix runtime smoke process exited early." >&2
      cat "$runtime_root/stdout.log" >&2 || true
      cat "$runtime_root/stderr.log" >&2 || true
      exit 1
    fi
    if body="$("$node_cmd" "$runtime_root/health-client.js" "http://127.0.0.1:$port/health" 2>/dev/null)"; then
      break
    fi
    sleep 0.25
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [[ -z "$body" ]]; then
    echo "Unix runtime smoke health check did not return a response." >&2
    cat "$runtime_root/stdout.log" >&2 || true
    cat "$runtime_root/stderr.log" >&2 || true
    exit 1
  fi
  if [[ "$body" != *'"appName":"example-next-runtime-smoke"'* ]]; then
    echo "Unix runtime smoke appName mismatch: $body" >&2
    exit 1
  fi
  if [[ "$body" != *"\"envPort\":\"$port\""* ]]; then
    echo "Unix runtime smoke PORT mismatch for port $port: $body" >&2
    exit 1
  fi
  if [[ "$body" != *'"envHostname":"127.0.0.1"'* ]]; then
    echo "Unix runtime smoke HOSTNAME mismatch: $body" >&2
    exit 1
  fi
}

echo "==> Unix Next.js support"

test_env_assignment_quoting
test_service_template_rendering
test_node_runtime_smoke

OK_ROOT="$TEST_ROOT/standalone-ok"
mkdir -p "$OK_ROOT"
new_standalone_layout "$OK_ROOT/app"
write_env "$OK_ROOT/app.env" "$OK_ROOT" 39200 "standalone" "server.js" "launchd"
expect_success "standalone preflight" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$OK_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_success "standalone runtime layout" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$OK_ROOT/app.env"
STATUS_JSON="$OK_ROOT/status.json"
expect_success "standalone safe status" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$OK_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$STATUS_JSON" --fail-on-critical
assert_contains "$STATUS_JSON" '"appName": "example-next-smoke"'
assert_contains "$STATUS_JSON" '"serviceEnabledStatus": "skipped"'
assert_contains "$STATUS_JSON" '"port": {'
assert_contains "$STATUS_JSON" '"checked": false'
assert_contains "$STATUS_JSON" '"health": {'
assert_contains "$STATUS_JSON" '"status": "skipped"'
assert_contains "$STATUS_JSON" '"uptime": {'
assert_contains "$STATUS_JSON" '"serviceStartKnown": false'
assert_contains "$STATUS_JSON" '"healthMonitor": {'
assert_contains "$STATUS_JSON" '"scheduleType": "launchd-timer"'
assert_contains "$STATUS_JSON" '"schedulerChecked": true'
assert_contains "$STATUS_JSON" '"schedulerExists": false'
assert_contains "$STATUS_JSON" '"stateExists": false'
assert_contains "$STATUS_JSON" '"logExists": false'
assert_contains "$STATUS_JSON" '"nextJsRuntime": {'
assert_contains "$STATUS_JSON" '"applicable": true'
assert_contains "$STATUS_JSON" '"status": "ok"'
assert_contains "$STATUS_JSON" '"appFramework": "nextjs"'
assert_contains "$STATUS_JSON" '"mode": "standalone"'
assert_contains "$STATUS_JSON" '"configFileName": "app.env"'
assert_contains "$STATUS_JSON" '"runtimeRootName": "app"'
assert_contains "$STATUS_JSON" '"deploymentIdentity": {'
assert_contains "$STATUS_JSON" '"appDirectoryName": "app"'
assert_contains "$STATUS_JSON" '"deploymentId": "example-deploy-001"'
assert_not_contains "$STATUS_JSON" '"configPath"'
assert_not_contains "$STATUS_JSON" '"runtimeRoot"'
assert_not_contains "$STATUS_JSON" '"appDirectory"'
assert_not_contains "$STATUS_JSON" "$OK_ROOT"
assert_contains "$STATUS_JSON" '"reverseProxy": {'
assert_contains "$STATUS_JSON" '"status": "not-applicable"'
assert_contains "$STATUS_JSON" '"verdict": "Warning"'
assert_contains "$STATUS_JSON" '"critical": 0'

PROXY_CONFIG_ROOT="$TEST_ROOT/proxy-config-ok"
mkdir -p "$PROXY_CONFIG_ROOT/nginx-conf"
new_standalone_layout "$PROXY_CONFIG_ROOT/app"
write_env "$PROXY_CONFIG_ROOT/app.env" "$PROXY_CONFIG_ROOT" 39206 "standalone" "server.js" "launchd"
write_file "$PROXY_CONFIG_ROOT/nginx-conf/example-next-smoke.conf" "# Managed by node-enterprise-deploy-kit for example-next-smoke."
cat >> "$PROXY_CONFIG_ROOT/app.env" <<EOF
REVERSE_PROXY="nginx"
NGINX_SITE_NAME="example-next-smoke"
NGINX_CONFIG_DIR="$PROXY_CONFIG_ROOT/nginx-conf"
PROXY_LISTEN_PORT="39980"
EOF
PROXY_STATUS_JSON="$PROXY_CONFIG_ROOT/status.json"
expect_success "standalone reverse proxy config status" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$PROXY_CONFIG_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$PROXY_STATUS_JSON" --fail-on-critical
assert_contains "$PROXY_STATUS_JSON" '"port": {'
assert_contains "$PROXY_STATUS_JSON" '"checked": false'
assert_contains "$PROXY_STATUS_JSON" '"health": {'
assert_contains "$PROXY_STATUS_JSON" '"status": "skipped"'
assert_contains "$PROXY_STATUS_JSON" '"uptime": {'
assert_contains "$PROXY_STATUS_JSON" '"serviceStartKnown": false'
assert_contains "$PROXY_STATUS_JSON" '"healthMonitor": {'
assert_contains "$PROXY_STATUS_JSON" '"scheduleType": "launchd-timer"'
assert_contains "$PROXY_STATUS_JSON" '"schedulerChecked": true'
assert_contains "$PROXY_STATUS_JSON" '"schedulerExists": false'
assert_contains "$PROXY_STATUS_JSON" '"stateExists": false'
assert_contains "$PROXY_STATUS_JSON" '"logExists": false'
assert_contains "$PROXY_STATUS_JSON" '"config": {'
assert_contains "$PROXY_STATUS_JSON" '"pathName": "example-next-smoke.conf"'
assert_contains "$PROXY_STATUS_JSON" '"directoryName": "nginx-conf"'
assert_contains "$PROXY_STATUS_JSON" '"exists": true'
assert_contains "$PROXY_STATUS_JSON" '"managedMarkerFound": true'
assert_contains "$PROXY_STATUS_JSON" '"expectedPort": "39980"'
assert_not_contains "$PROXY_STATUS_JSON" "$PROXY_CONFIG_ROOT"

BAD_ROOT="$TEST_ROOT/standalone-missing-static"
mkdir -p "$BAD_ROOT/app/.next" "$BAD_ROOT/app/node_modules"
write_file "$BAD_ROOT/app/server.js" "console.log('missing static');"
write_env "$BAD_ROOT/app.env" "$BAD_ROOT" 39201 "standalone" "server.js" "launchd"
expect_failure "standalone missing static preflight" ".next/static" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$BAD_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_failure "standalone missing static runtime layout" ".next/static" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$BAD_ROOT/app.env"
expect_failure "standalone missing static safe status" ".next/static" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$BAD_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --fail-on-critical

NEXT_START_ROOT="$TEST_ROOT/next-start-ok"
mkdir -p "$NEXT_START_ROOT"
new_next_start_layout "$NEXT_START_ROOT/app"
write_env "$NEXT_START_ROOT/app.env" "$NEXT_START_ROOT" 39202 "next-start" "node_modules/next/dist/bin/next" "launchd"
expect_success "next-start preflight" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$NEXT_START_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_success "next-start runtime layout" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$NEXT_START_ROOT/app.env"

BAD_NEXT_START_ARGS_ROOT="$TEST_ROOT/next-start-missing-host-arg"
mkdir -p "$BAD_NEXT_START_ARGS_ROOT"
new_next_start_layout "$BAD_NEXT_START_ARGS_ROOT/app"
write_env "$BAD_NEXT_START_ARGS_ROOT/app.env" "$BAD_NEXT_START_ARGS_ROOT" 39204 "next-start" "node_modules/next/dist/bin/next" "launchd" "start"
expect_failure "next-start missing host arg preflight" "requires NODE_ARGUMENTS to include '-H" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$BAD_NEXT_START_ARGS_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_failure "next-start missing host arg runtime layout" "requires NODE_ARGUMENTS to include '-H" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$BAD_NEXT_START_ARGS_ROOT/app.env"

PACKAGE_PROJECT="$TEST_ROOT/package-project"
PACKAGE_PATH="$TEST_ROOT/package/example-next.tar.gz"
new_next_project_layout "$PACKAGE_PROJECT"
expect_success "package helper" bash "$REPO_ROOT/scripts/linux/package-nextjs-standalone.sh" --project-path "$PACKAGE_PROJECT" --output-path "$PACKAGE_PATH"
expect_success "package validator" bash "$REPO_ROOT/scripts/linux/validate-nextjs-standalone-package.sh" --package-path "$PACKAGE_PATH"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  IMPORT_ROOT="$TEST_ROOT/import-ok"
  mkdir -p "$IMPORT_ROOT"
  write_env "$IMPORT_ROOT/app.env" "$IMPORT_ROOT" 39205 "standalone" "server.js" "launchd"
  expect_success "root package import manifest" bash "$REPO_ROOT/scripts/linux/import-app-package.sh" "$IMPORT_ROOT/app.env" "$PACKAGE_PATH"
  IMPORT_MANIFEST="$IMPORT_ROOT/app/.node-enterprise-deploy.json"
  STATUS_IMPORT_JSON="$IMPORT_ROOT/status-import.json"
  if command -v sha256sum >/dev/null 2>&1; then
    PACKAGE_SHA256="$(sha256sum "$PACKAGE_PATH" | awk '{ print tolower($1) }')"
  elif command -v shasum >/dev/null 2>&1; then
    PACKAGE_SHA256="$(shasum -a 256 "$PACKAGE_PATH" | awk '{ print tolower($1) }')"
  else
    PACKAGE_SHA256=""
  fi
  assert_contains "$IMPORT_MANIFEST" '"packageName": "example-next.tar.gz"'
  assert_contains "$IMPORT_MANIFEST" '"nextBuildId": "example-build"'
  if [[ -n "$PACKAGE_SHA256" ]]; then
    assert_contains "$IMPORT_MANIFEST" "\"packageSha256\": \"$PACKAGE_SHA256\""
  fi
  assert_not_contains "$IMPORT_MANIFEST" "$PACKAGE_PATH"
  assert_not_contains "$IMPORT_MANIFEST" "$IMPORT_ROOT"
  expect_success "root package import status manifest" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$IMPORT_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$STATUS_IMPORT_JSON"
  assert_contains "$STATUS_IMPORT_JSON" '"manifestExists": true'
  assert_contains "$STATUS_IMPORT_JSON" '"packageName": "example-next.tar.gz"'
  assert_contains "$STATUS_IMPORT_JSON" '"nextBuildId": "example-build"'
  assert_not_contains "$STATUS_IMPORT_JSON" "$PACKAGE_PATH"
  assert_not_contains "$STATUS_IMPORT_JSON" "$IMPORT_ROOT"
else
  echo "Skipping root package import manifest smoke; package import intentionally requires root."
fi

NEXT_START_PACKAGE="$TEST_ROOT/package/next-start.tar.gz"
tar -C "$NEXT_START_ROOT/app" -czf "$NEXT_START_PACKAGE" .
expect_success "next-start package validator" bash "$REPO_ROOT/scripts/linux/validate-nextjs-standalone-package.sh" --package-path "$NEXT_START_PACKAGE" --mode next-start

BAD_NEXT_START_PACKAGE="$TEST_ROOT/package/next-start-missing-next.tar.gz"
tar -C "$BAD_ROOT/app" -czf "$BAD_NEXT_START_PACKAGE" .
expect_failure "next-start missing next package validator" "package.json" bash "$REPO_ROOT/scripts/linux/validate-nextjs-standalone-package.sh" --package-path "$BAD_NEXT_START_PACKAGE" --mode next-start

UNSAFE_LINK_ROOT="$TEST_ROOT/package-unsafe-link"
UNSAFE_LINK_PACKAGE="$TEST_ROOT/package/unsafe-link.tar.gz"
new_standalone_layout "$UNSAFE_LINK_ROOT"
if ln -s /etc/passwd "$UNSAFE_LINK_ROOT/unsafe-link" 2>/dev/null && [[ -L "$UNSAFE_LINK_ROOT/unsafe-link" ]]; then
  mkdir -p "$(dirname "$UNSAFE_LINK_PACKAGE")"
  tar -C "$UNSAFE_LINK_ROOT" -czf "$UNSAFE_LINK_PACKAGE" .
  expect_failure "unsafe link package validator" "Unsafe tar link entry" bash "$REPO_ROOT/scripts/linux/validate-nextjs-standalone-package.sh" --package-path "$UNSAFE_LINK_PACKAGE"

  UNSAFE_HELPER_PROJECT="$TEST_ROOT/package-helper-unsafe-link"
  new_next_project_layout "$UNSAFE_HELPER_PROJECT"
  ln -s /etc/passwd "$UNSAFE_HELPER_PROJECT/.next/standalone/unsafe-link"
  expect_failure "unsafe link package helper" "Unsafe tar link entry" bash "$REPO_ROOT/scripts/linux/package-nextjs-standalone.sh" --project-path "$UNSAFE_HELPER_PROJECT" --output-path "$TEST_ROOT/package/unsafe-helper.tar.gz"
else
  echo "Skipping unsafe symlink package check; this shell cannot create real symlinks."
fi

BLOCKED_PROJECT="$TEST_ROOT/package-blocked"
new_next_project_layout "$BLOCKED_PROJECT"
write_file "$BLOCKED_PROJECT/.next/standalone/.env.production" "SECRET_VALUE=placeholder"
expect_failure "blocked package helper" "blocked private file" bash "$REPO_ROOT/scripts/linux/package-nextjs-standalone.sh" --project-path "$BLOCKED_PROJECT" --output-path "$TEST_ROOT/package/blocked.tar.gz"

BSD_ROOT="$TEST_ROOT/bsdrc-ok"
mkdir -p "$BSD_ROOT"
new_standalone_layout "$BSD_ROOT/app"
write_env "$BSD_ROOT/app.env" "$BSD_ROOT" 39203 "standalone" "server.js" "bsdrc"
expect_success "bsdrc static preflight" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$BSD_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check

echo "Unix Next.js support checks OK"
