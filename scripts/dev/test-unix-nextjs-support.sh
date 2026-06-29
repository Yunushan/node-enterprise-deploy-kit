#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="${TEST_ROOT:-$REPO_ROOT/.tmp/unix-nextjs-support-$$}"

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

copy_command_to_fake_path() {
  local fake_bin="$1" command_name="$2" source_path
  source_path="$(type -P "$command_name" 2>/dev/null || true)"
  if [[ -z "$source_path" ]]; then
    echo "Could not find required test command: $command_name" >&2
    exit 1
  fi
  cp "$source_path" "$fake_bin/$command_name"
  chmod 0755 "$fake_bin/$command_name"
}

new_fake_preflight_path_without_schedulers() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  for command_name in dirname pwd uname tr grep sed basename tail; do
    copy_command_to_fake_path "$fake_bin" "$command_name"
  done
}

run_preflight_with_path() {
  local fake_path="$1" env_file="$2"
  PATH="$fake_path" "$BASH" "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$env_file" --skip-reverse-proxy --skip-service-manager-check
}

run_preflight_without_proxy_bins() {
  local fake_path="$1" env_file="$2"
  PATH="$fake_path" "$BASH" "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$env_file" --skip-health-check --skip-service-manager-check
}

test_health_scheduler_preflight_requirements() {
  local fake_bin="$TEST_ROOT/fake-bin-no-schedulers"
  new_fake_preflight_path_without_schedulers "$fake_bin"

  local systemd_root="$TEST_ROOT/preflight-health-systemd"
  mkdir -p "$systemd_root"
  new_standalone_layout "$systemd_root/app"
  write_env "$systemd_root/app.env" "$systemd_root" 39214 "standalone" "server.js" "systemd"
  expect_failure "systemd health scheduler preflight" "Healthcheck scheduler requires systemctl" run_preflight_with_path "$fake_bin" "$systemd_root/app.env"

  local launchd_root="$TEST_ROOT/preflight-health-launchd"
  mkdir -p "$launchd_root"
  new_standalone_layout "$launchd_root/app"
  write_env "$launchd_root/app.env" "$launchd_root" 39215 "standalone" "server.js" "launchd"
  expect_failure "launchd health scheduler preflight" "Healthcheck scheduler requires launchctl" run_preflight_with_path "$fake_bin" "$launchd_root/app.env"

  local bsdrc_root="$TEST_ROOT/preflight-health-bsdrc"
  mkdir -p "$bsdrc_root"
  new_standalone_layout "$bsdrc_root/app"
  write_env "$bsdrc_root/app.env" "$bsdrc_root" 39216 "standalone" "server.js" "bsdrc"
  expect_failure "bsdrc health scheduler preflight" "Healthcheck scheduler requires crontab" run_preflight_with_path "$fake_bin" "$bsdrc_root/app.env"
}

test_reverse_proxy_preflight_requires_binary() {
  local fake_bin="$TEST_ROOT/fake-bin-no-proxies"
  new_fake_preflight_path_without_schedulers "$fake_bin"

  local proxy expected proxy_root
  for proxy in nginx apache haproxy traefik; do
    proxy_root="$TEST_ROOT/preflight-reverse-proxy-$proxy"
    mkdir -p "$proxy_root"
    new_standalone_layout "$proxy_root/app"
    write_env "$proxy_root/app.env" "$proxy_root" 39219 "standalone" "server.js" "launchd"
    cat >> "$proxy_root/app.env" <<EOF
REVERSE_PROXY="$proxy"
EOF
    case "$proxy" in
      nginx) expected="REVERSE_PROXY=nginx but nginx was not found" ;;
      apache) expected="REVERSE_PROXY=apache but apache2ctl/httpd was not found" ;;
      haproxy) expected="REVERSE_PROXY=haproxy but haproxy was not found" ;;
      traefik) expected="REVERSE_PROXY=traefik but traefik was not found" ;;
    esac
    expect_failure "$proxy reverse proxy binary preflight" "$expected" run_preflight_without_proxy_bins "$fake_bin" "$proxy_root/app.env"
  done
}

write_minimal_env_without_service_manager() {
  local path="$1" root="$2" port="$3"
  cat > "$path" <<EOF
APP_NAME="example-next-smoke"
APP_RUNTIME="node"
APP_DIR="$root/app"
APP_PORT="$port"
HEALTH_URL="http://127.0.0.1:$port/health"
LOG_DIR="$root/logs"
HEALTHCHECK_STATE_DIR="$root/state"
REVERSE_PROXY="none"
EOF
}

write_fake_host_command() {
  local fake_bin="$1" command_name="$2"
  shift 2
  mkdir -p "$fake_bin"
  printf '%s\n' "$@" > "$fake_bin/$command_name"
  chmod 0755 "$fake_bin/$command_name"
}

new_fake_host_path() {
  local fake_bin="$1" kernel="$2"
  mkdir -p "$fake_bin"
  write_fake_host_command "$fake_bin" "uname" \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "-s" ]]; then printf "%s\n" "'"$kernel"'"; else printf "%s\n" "'"$kernel"'"; fi'
  write_fake_host_command "$fake_bin" "curl" \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "curl $*" >> "$NODE_EDK_TRACE_FILE"' \
    'exit 0'
  write_fake_host_command "$fake_bin" "systemctl" \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "systemctl $*" >> "$NODE_EDK_TRACE_FILE"' \
    'exit 77'
  write_fake_host_command "$fake_bin" "launchctl" \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "launchctl $*" >> "$NODE_EDK_TRACE_FILE"' \
    'exit 0'
  write_fake_host_command "$fake_bin" "service" \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "service $*" >> "$NODE_EDK_TRACE_FILE"' \
    'exit 0'
}

new_fake_dependency_bootstrap_path() {
  local fake_bin="$1" kernel="$2"
  mkdir -p "$fake_bin"
  for command_name in dirname pwd uname tr grep sed; do
    if [[ "$command_name" == "uname" ]]; then
      write_fake_host_command "$fake_bin" "uname" \
        '#!/bin/sh' \
        'if [ "${1:-}" = "-s" ]; then printf "%s\n" "'"$kernel"'"; else printf "%s\n" "'"$kernel"'"; fi'
    else
      copy_command_to_fake_path "$fake_bin" "$command_name"
    fi
  done
}

test_dependency_bootstrap_requires_package_manager() {
  local macos_root="$TEST_ROOT/dependency-bootstrap-macos"
  local macos_fake_bin="$macos_root/fake-bin"
  mkdir -p "$macos_root"
  new_fake_dependency_bootstrap_path "$macos_fake_bin" "Darwin"

  expect_failure "macOS dependency bootstrap without Homebrew" "Homebrew was not found" env PATH="$macos_fake_bin" "$BASH" "$REPO_ROOT/scripts/linux/install-dependencies.sh"
  assert_contains "$REPO_ROOT/scripts/linux/install-dependencies.sh" "Neither dnf nor yum was found"
  assert_contains "$REPO_ROOT/scripts/linux/install-dependencies.sh" "pkgin was not found"
  assert_contains "$REPO_ROOT/scripts/linux/install-dependencies.sh" "Unsupported/unknown OS family"
}

test_host_aware_service_manager_defaults() {
  local darwin_root="$TEST_ROOT/default-manager-darwin"
  local darwin_fake_bin="$darwin_root/fake-bin"
  local darwin_trace="$darwin_root/trace.log"
  mkdir -p "$darwin_root"
  write_minimal_env_without_service_manager "$darwin_root/app.env" "$darwin_root" 39217
  new_fake_host_path "$darwin_fake_bin" "Darwin"
  expect_success "darwin healthcheck default manager" env NODE_EDK_TRACE_FILE="$darwin_trace" PATH="$darwin_fake_bin:$PATH" bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$darwin_root/app.env"
  assert_contains "$darwin_trace" "launchctl print system/example-next-smoke"
  assert_not_contains "$darwin_trace" "systemctl"

  local darwin_diag_dir="$darwin_root/diagnostics"
  expect_success "darwin diagnostics default manager" env NODE_EDK_TRACE_FILE="$darwin_trace" PATH="$darwin_fake_bin:$PATH" bash "$REPO_ROOT/scripts/linux/diagnose-node-app.sh" "$darwin_root/app.env" "$darwin_diag_dir"
  local darwin_diag_file
  darwin_diag_file="$(ls "$darwin_diag_dir"/diagnostics-*.txt | tail -n 1)"
  assert_contains "$darwin_diag_file" "ServiceManager=launchd"

  local freebsd_root="$TEST_ROOT/default-manager-freebsd"
  local freebsd_fake_bin="$freebsd_root/fake-bin"
  local freebsd_trace="$freebsd_root/trace.log"
  mkdir -p "$freebsd_root"
  write_minimal_env_without_service_manager "$freebsd_root/app.env" "$freebsd_root" 39218
  new_fake_host_path "$freebsd_fake_bin" "FreeBSD"
  expect_success "freebsd healthcheck default manager" env NODE_EDK_TRACE_FILE="$freebsd_trace" PATH="$freebsd_fake_bin:$PATH" bash "$REPO_ROOT/scripts/linux/node-healthcheck.sh" "$freebsd_root/app.env"
  assert_contains "$freebsd_trace" "service example-next-smoke status"
  assert_not_contains "$freebsd_trace" "systemctl"

  assert_contains "$REPO_ROOT/scripts/linux/uninstall-node-service.sh" 'default_service_manager "$PLATFORM_FAMILY"'
  assert_contains "$REPO_ROOT/scripts/linux/uninstall-node-service.sh" '${APP_NAME}-healthcheck.plist'
  assert_contains "$REPO_ROOT/scripts/linux/uninstall-node-service.sh" 'node-enterprise-deploy-kit:${APP_NAME}:healthcheck:start'
  assert_contains "$REPO_ROOT/scripts/linux/uninstall-node-service.sh" 'rm -f "$HC_CONFIG" "$HC_SCRIPT"'
}

assert_contains() {
  local path="$1" expected="$2"
  if ! grep -Fq -- "$expected" "$path"; then
    echo "$path is missing expected text: $expected" >&2
    printf '%s\n' "--- $path ---" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$path"; then
    echo "$path contains unexpected text: $unexpected" >&2
    printf '%s\n' "--- $path ---" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_no_template_tokens() {
  local path="$1"
  if grep -Eq '\{\{[A-Za-z0-9_]+\}\}' "$path"; then
    echo "$path contains unresolved template tokens." >&2
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

render_reverse_proxy_template() {
  local template="$1" output="$2"
  BACKUP_DIR="$TEST_ROOT/backups" render_template_file "$template" "$output" \
    APP_NAME "example-next-smoke" \
    PUBLIC_HOSTNAME "app.example.test" \
    PROXY_LISTEN_PORT "39981" \
    APP_PORT "39210" \
    HEALTH_URL "http://127.0.0.1:39210/health" \
    LOG_DIR "$TEST_ROOT/rendered-proxy/logs" \
    FORWARDED_PROTO "https" \
    FORWARDED_PORT "443" \
    HAPROXY_BIND "*:39981" \
    HAPROXY_FRONTEND_NAME "example_next_smoke_fe" \
    HAPROXY_BACKEND_NAME "example_next_smoke_be" \
    HEALTHCHECK_PATH "/health" \
    TRAEFIK_ENTRYPOINT "websecure" \
    TRAEFIK_ROUTER_NAME "example-next-smoke-router" \
    TRAEFIK_SERVICE_NAME "example-next-smoke-service"
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

test_reverse_proxy_template_rendering() {
  local rendered="$TEST_ROOT/rendered-proxy"
  mkdir -p "$rendered"

  render_reverse_proxy_template "$REPO_ROOT/templates/linux/nginx-site.conf.tpl" "$rendered/example-next-smoke.nginx.conf"
  render_reverse_proxy_template "$REPO_ROOT/templates/linux/apache-vhost.conf.tpl" "$rendered/example-next-smoke.apache.conf"
  render_reverse_proxy_template "$REPO_ROOT/templates/linux/haproxy.cfg.tpl" "$rendered/example-next-smoke.haproxy.cfg"
  render_reverse_proxy_template "$REPO_ROOT/templates/linux/traefik-dynamic.yml.tpl" "$rendered/example-next-smoke.traefik.yml"

  assert_no_template_tokens "$rendered/example-next-smoke.nginx.conf"
  assert_contains "$rendered/example-next-smoke.nginx.conf" "# Managed by node-enterprise-deploy-kit for example-next-smoke."
  assert_contains "$rendered/example-next-smoke.nginx.conf" "listen 39981;"
  assert_contains "$rendered/example-next-smoke.nginx.conf" "server_name app.example.test;"
  assert_contains "$rendered/example-next-smoke.nginx.conf" "proxy_pass http://127.0.0.1:39210;"
  assert_contains "$rendered/example-next-smoke.nginx.conf" "proxy_set_header X-Forwarded-Proto https;"
  assert_contains "$rendered/example-next-smoke.nginx.conf" "proxy_set_header X-Forwarded-Port 443;"
  assert_contains "$rendered/example-next-smoke.nginx.conf" 'proxy_set_header Upgrade $http_upgrade;'
  assert_contains "$rendered/example-next-smoke.nginx.conf" "proxy_pass http://127.0.0.1:39210/health;"

  assert_no_template_tokens "$rendered/example-next-smoke.apache.conf"
  assert_contains "$rendered/example-next-smoke.apache.conf" "# Managed by node-enterprise-deploy-kit for example-next-smoke."
  assert_contains "$rendered/example-next-smoke.apache.conf" "<VirtualHost *:39981>"
  assert_contains "$rendered/example-next-smoke.apache.conf" "ServerName app.example.test"
  assert_contains "$rendered/example-next-smoke.apache.conf" "RequestHeader set X-Forwarded-Proto \"https\""
  assert_contains "$rendered/example-next-smoke.apache.conf" "RequestHeader set X-Forwarded-Port \"443\""
  assert_contains "$rendered/example-next-smoke.apache.conf" 'RewriteRule /(.*) ws://127.0.0.1:39210/$1 [P,L]'
  assert_contains "$rendered/example-next-smoke.apache.conf" "ProxyPass /health-proxy http://127.0.0.1:39210/health"
  assert_contains "$rendered/example-next-smoke.apache.conf" "ProxyPass / http://127.0.0.1:39210/"

  assert_no_template_tokens "$rendered/example-next-smoke.haproxy.cfg"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "# Managed by node-enterprise-deploy-kit for example-next-smoke."
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "frontend example_next_smoke_fe"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "bind *:39981"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "http-request set-header X-Forwarded-Proto https"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "http-request set-header X-Forwarded-Port 443"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "backend example_next_smoke_be"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "option httpchk GET /health"
  assert_contains "$rendered/example-next-smoke.haproxy.cfg" "server example-next-smoke 127.0.0.1:39210 check"

  assert_no_template_tokens "$rendered/example-next-smoke.traefik.yml"
  assert_contains "$rendered/example-next-smoke.traefik.yml" "# Managed by node-enterprise-deploy-kit for example-next-smoke."
  assert_contains "$rendered/example-next-smoke.traefik.yml" "example-next-smoke-router:"
  assert_contains "$rendered/example-next-smoke.traefik.yml" 'rule: "Host(`app.example.test`)"'
  assert_contains "$rendered/example-next-smoke.traefik.yml" '- "websecure"'
  assert_contains "$rendered/example-next-smoke.traefik.yml" 'service: "example-next-smoke-service"'
  assert_contains "$rendered/example-next-smoke.traefik.yml" "loadBalancer:"
  assert_contains "$rendered/example-next-smoke.traefik.yml" 'path: "/health"'
  assert_contains "$rendered/example-next-smoke.traefik.yml" '- url: "http://127.0.0.1:39210"'
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
  run_node_runtime_smoke_case "$node_cmd" "standalone"
  run_node_runtime_smoke_case "$node_cmd" "next-start"
}

write_node_runtime_smoke_server() {
  local output_path="$1"
  cat > "$output_path" <<'NODE'
const http = require('http');

const mode = process.env.NEXTJS_DEPLOYMENT_MODE || 'standalone';
const args = process.argv.slice(2);
let cliHost = '';
for (let i = 0; i < args.length; i += 1) {
  if ((args[i] === '-H' || args[i] === '--hostname') && i + 1 < args.length) {
    cliHost = args[i + 1];
  } else if (args[i].startsWith('--hostname=')) {
    cliHost = args[i].slice('--hostname='.length);
  } else if (args[i].startsWith('-H=')) {
    cliHost = args[i].slice('-H='.length);
  }
}

if (mode === 'next-start') {
  if (args[0] !== 'start') {
    console.error(`expected first Next.js CLI argument to be start, got ${args[0] || '<empty>'}`);
    process.exit(2);
  }
  if (cliHost !== (process.env.BIND_ADDRESS || '127.0.0.1')) {
    console.error(`expected Next.js CLI hostname ${process.env.BIND_ADDRESS || '127.0.0.1'}, got ${cliHost || '<empty>'}`);
    process.exit(2);
  }
}

const host = cliHost || process.env.HOSTNAME || process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || process.env.APP_PORT || 3000);
const appName = process.env.APP_NAME || 'unknown-app';
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      appName,
      host,
      mode,
      args,
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
}

write_node_runtime_smoke_client() {
  local output_path="$1"
  cat > "$output_path" <<'NODE'
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
}

print_file_to_stderr() {
  local file_path="$1"
  [[ -f "$file_path" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&2
  done < "$file_path"
}

run_node_runtime_smoke_case() {
  local node_cmd="$1" mode="$2"
  local port
  port="$("$node_cmd" -e "const net=require('net'); const s=net.createServer(); s.listen(0,'127.0.0.1',()=>{ console.log(s.address().port); s.close(); });")"
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
    echo "Could not allocate a free loopback port for Unix runtime smoke." >&2
    exit 1
  fi
  local runtime_root="$TEST_ROOT/runtime-smoke-$mode"
  local app_dir="$runtime_root/app"
  local pid=""
  mkdir -p "$app_dir/.next/static" "$app_dir/node_modules"
  write_file "$app_dir/.next/BUILD_ID" "example-build"
  write_file "$app_dir/.next/static/app.js" "console.log('static');"
  write_node_runtime_smoke_client "$runtime_root/health-client.js"

  local app_name="example-next-runtime-smoke-$mode"
  local command_args=()
  if [[ "$mode" == "next-start" ]]; then
    local next_cli="$app_dir/node_modules/next/dist/bin/next"
    mkdir -p "$(dirname "$next_cli")"
    write_node_runtime_smoke_server "$next_cli"
    write_file "$app_dir/package.json" '{"scripts":{"start":"next start"},"dependencies":{"next":"0.0.0-smoke"}}'
    command_args=("node_modules/next/dist/bin/next" "start" "-H" "127.0.0.1")
  else
    write_node_runtime_smoke_server "$app_dir/server.js"
    command_args=("server.js")
  fi

  (
    cd "$app_dir"
    NODE_ENV="production" \
      PORT="$port" \
      APP_PORT="$port" \
      APP_NAME="$app_name" \
      NEXTJS_DEPLOYMENT_MODE="$mode" \
      BIND_ADDRESS="127.0.0.1" \
      HOST="127.0.0.1" \
      HOSTNAME="127.0.0.1" \
      "$node_cmd" "${command_args[@]}" > "$runtime_root/stdout.log" 2> "$runtime_root/stderr.log"
  ) &
  pid="$!"

  local deadline=$((SECONDS + 15))
  local body=""
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Unix runtime smoke process exited early." >&2
      print_file_to_stderr "$runtime_root/stdout.log"
      print_file_to_stderr "$runtime_root/stderr.log"
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
    echo "Unix $mode runtime smoke health check did not return a response." >&2
    print_file_to_stderr "$runtime_root/stdout.log"
    print_file_to_stderr "$runtime_root/stderr.log"
    exit 1
  fi
  if [[ "$body" != *"\"appName\":\"$app_name\""* ]]; then
    echo "Unix $mode runtime smoke appName mismatch: $body" >&2
    exit 1
  fi
  if [[ "$body" != *"\"mode\":\"$mode\""* ]]; then
    echo "Unix $mode runtime smoke mode mismatch: $body" >&2
    exit 1
  fi
  if [[ "$body" != *'"host":"127.0.0.1"'* ]]; then
    echo "Unix $mode runtime smoke host mismatch: $body" >&2
    exit 1
  fi
  if [[ "$body" != *"\"envPort\":\"$port\""* ]]; then
    echo "Unix $mode runtime smoke PORT mismatch for port $port: $body" >&2
    exit 1
  fi
  if [[ "$body" != *'"envHostname":"127.0.0.1"'* ]]; then
    echo "Unix $mode runtime smoke HOSTNAME mismatch: $body" >&2
    exit 1
  fi
  if [[ "$mode" == "next-start" && "$body" != *'"args":["start","-H","127.0.0.1"]'* ]]; then
    echo "Unix next-start runtime smoke arguments mismatch: $body" >&2
    exit 1
  fi
  echo "Unix $mode runtime smoke OK on 127.0.0.1:$port"
}

echo "==> Unix Next.js support"

test_env_assignment_quoting
test_service_template_rendering
test_reverse_proxy_template_rendering
test_node_runtime_smoke
test_health_scheduler_preflight_requirements
test_reverse_proxy_preflight_requires_binary
test_dependency_bootstrap_requires_package_manager
test_host_aware_service_manager_defaults

OK_ROOT="$TEST_ROOT/standalone-ok"
mkdir -p "$OK_ROOT"
new_standalone_layout "$OK_ROOT/app"
write_env "$OK_ROOT/app.env" "$OK_ROOT" 39200 "standalone" "server.js" "launchd"
expect_success "standalone preflight" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$OK_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_success "standalone runtime layout" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$OK_ROOT/app.env"
STATUS_JSON="$OK_ROOT/status.json"
expect_success "standalone safe status" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$OK_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$STATUS_JSON" --fail-on-critical
assert_contains "$STATUS_JSON" '"appName": "example-next-smoke"'
assert_contains "$STATUS_JSON" '"supportTargetId": "'
assert_contains "$STATUS_JSON" '"serviceEnabledStatus": "skipped"'
assert_contains "$STATUS_JSON" '"serviceDefinition": {'
assert_contains "$STATUS_JSON" '"definitionSource": "skipped"'
assert_contains "$STATUS_JSON" '"definitionExists": false'
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

SUBDIR_ROOT="$TEST_ROOT/standalone-subdir-runtime"
mkdir -p "$SUBDIR_ROOT/app"
new_standalone_layout "$SUBDIR_ROOT/app/runtime"
write_env "$SUBDIR_ROOT/app.env" "$SUBDIR_ROOT" 39220 "standalone" "runtime/server.js" "launchd"
expect_success "standalone subdir preflight" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$SUBDIR_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_success "standalone subdir runtime layout" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$SUBDIR_ROOT/app.env"
SUBDIR_STATUS_JSON="$SUBDIR_ROOT/status.json"
expect_success "standalone subdir safe status" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$SUBDIR_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$SUBDIR_STATUS_JSON" --fail-on-critical
assert_contains "$SUBDIR_STATUS_JSON" '"runtimeRootName": "runtime"'
assert_contains "$SUBDIR_STATUS_JSON" '"appDirectoryName": "app"'
assert_contains "$SUBDIR_STATUS_JSON" '"nextBuildId": "example-build"'
assert_not_contains "$SUBDIR_STATUS_JSON" "$SUBDIR_ROOT"

test_reverse_proxy_config_status() {
  local proxy="$1" config_dir_name="$2" config_file_name="$3" extra_env="$4"
  local proxy_root="$TEST_ROOT/proxy-config-$proxy-ok"
  mkdir -p "$proxy_root/$config_dir_name"
  new_standalone_layout "$proxy_root/app"
  write_env "$proxy_root/app.env" "$proxy_root" 39206 "standalone" "server.js" "launchd"
  write_file "$proxy_root/$config_dir_name/$config_file_name" "# Managed by node-enterprise-deploy-kit for example-next-smoke."
  cat >> "$proxy_root/app.env" <<EOF
REVERSE_PROXY="$proxy"
PROXY_LISTEN_PORT="39980"
$extra_env
EOF
  local status_json="$proxy_root/status.json"
  expect_success "$proxy reverse proxy config status" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$proxy_root/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$status_json" --fail-on-critical
  assert_contains "$status_json" '"supportTargetId": "'
  assert_contains "$status_json" '"port": {'
  assert_contains "$status_json" '"checked": false'
  assert_contains "$status_json" '"health": {'
  assert_contains "$status_json" '"status": "skipped"'
  assert_contains "$status_json" '"uptime": {'
  assert_contains "$status_json" '"serviceStartKnown": false'
  assert_contains "$status_json" '"healthMonitor": {'
  assert_contains "$status_json" '"scheduleType": "launchd-timer"'
  assert_contains "$status_json" '"schedulerChecked": true'
  assert_contains "$status_json" '"schedulerExists": false'
  assert_contains "$status_json" '"stateExists": false'
  assert_contains "$status_json" '"logExists": false'
  assert_contains "$status_json" '"reverseProxy": {'
  assert_contains "$status_json" "\"mode\": \"$proxy\""
  assert_contains "$status_json" '"config": {'
  assert_contains "$status_json" "\"pathName\": \"$config_file_name\""
  assert_contains "$status_json" "\"directoryName\": \"$config_dir_name\""
  assert_contains "$status_json" '"exists": true'
  assert_contains "$status_json" '"managedMarkerFound": true'
  assert_contains "$status_json" '"expectedPort": "39980"'
  assert_not_contains "$status_json" "$proxy_root"
}

test_reverse_proxy_config_status "nginx" "nginx-conf" "example-next-smoke.conf" "NGINX_SITE_NAME=\"example-next-smoke\"
NGINX_CONFIG_DIR=\"$TEST_ROOT/proxy-config-nginx-ok/nginx-conf\""
test_reverse_proxy_config_status "apache" "apache-conf" "example-next-smoke.conf" "APACHE_SITE_NAME=\"example-next-smoke\"
APACHE_CONFIG_DIR=\"$TEST_ROOT/proxy-config-apache-ok/apache-conf\""
test_reverse_proxy_config_status "haproxy" "haproxy-conf" "haproxy.cfg" "HAPROXY_CONFIG_FILE=\"$TEST_ROOT/proxy-config-haproxy-ok/haproxy-conf/haproxy.cfg\""
test_reverse_proxy_config_status "traefik" "traefik-conf" "example-next-smoke.yml" "TRAEFIK_DYNAMIC_FILE=\"$TEST_ROOT/proxy-config-traefik-ok/traefik-conf/example-next-smoke.yml\""

test_reverse_proxy_dispatcher() {
  local proxy="$1" expected_installer="$2"
  local proxy_root="$TEST_ROOT/reverse-proxy-dispatch-$proxy"
  local output="$proxy_root/output.txt"
  mkdir -p "$proxy_root"
  new_standalone_layout "$proxy_root/app"
  write_env "$proxy_root/app.env" "$proxy_root" 39211 "standalone" "server.js" "launchd"
  cat >> "$proxy_root/app.env" <<EOF
REVERSE_PROXY="$proxy"
EOF
  expect_success "$proxy reverse proxy dispatcher dry-run" bash "$REPO_ROOT/scripts/linux/install-reverse-proxy.sh" "$proxy_root/app.env" --dry-run > "$output"
  assert_contains "$output" "$expected_installer"
  assert_contains "$output" "$proxy_root/app.env"
  assert_not_contains "$output" "sudo"
}

test_reverse_proxy_dispatcher "nginx" "install-nginx-reverse-proxy.sh"
test_reverse_proxy_dispatcher "apache" "install-apache-reverse-proxy.sh"
test_reverse_proxy_dispatcher "httpd" "install-apache-reverse-proxy.sh"
test_reverse_proxy_dispatcher "haproxy" "install-haproxy-reverse-proxy.sh"
test_reverse_proxy_dispatcher "traefik" "install-traefik-reverse-proxy.sh"

DISPATCH_NONE_ROOT="$TEST_ROOT/reverse-proxy-dispatch-none"
mkdir -p "$DISPATCH_NONE_ROOT"
new_standalone_layout "$DISPATCH_NONE_ROOT/app"
write_env "$DISPATCH_NONE_ROOT/app.env" "$DISPATCH_NONE_ROOT" 39212 "standalone" "server.js" "launchd"
expect_success "none reverse proxy dispatcher" bash "$REPO_ROOT/scripts/linux/install-reverse-proxy.sh" "$DISPATCH_NONE_ROOT/app.env"

DISPATCH_BAD_ROOT="$TEST_ROOT/reverse-proxy-dispatch-bad"
mkdir -p "$DISPATCH_BAD_ROOT"
new_standalone_layout "$DISPATCH_BAD_ROOT/app"
write_env "$DISPATCH_BAD_ROOT/app.env" "$DISPATCH_BAD_ROOT" 39213 "standalone" "server.js" "launchd"
cat >> "$DISPATCH_BAD_ROOT/app.env" <<'EOF'
REVERSE_PROXY="caddy"
EOF
expect_failure "bad reverse proxy dispatcher" "Unsupported REVERSE_PROXY" bash "$REPO_ROOT/scripts/linux/install-reverse-proxy.sh" "$DISPATCH_BAD_ROOT/app.env" --dry-run

test_static_service_manager_status() {
  local manager="$1" port="$2" expected_schedule="$3"
  local manager_root="$TEST_ROOT/service-manager-$manager-ok"
  local status_json="$manager_root/status.json"
  mkdir -p "$manager_root"
  new_standalone_layout "$manager_root/app"
  write_env "$manager_root/app.env" "$manager_root" "$port" "standalone" "server.js" "$manager"
  expect_success "$manager static preflight" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$manager_root/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
  expect_success "$manager runtime layout" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$manager_root/app.env"
  expect_success "$manager safe status" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$manager_root/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --json-output "$status_json" --fail-on-critical
  assert_contains "$status_json" "\"serviceManager\": \"$manager\""
  assert_contains "$status_json" '"serviceActiveStatus": "skipped"'
  assert_contains "$status_json" '"serviceEnabledStatus": "skipped"'
  assert_contains "$status_json" '"healthMonitor": {'
  assert_contains "$status_json" "\"scheduleType\": \"$expected_schedule\""
  assert_contains "$status_json" '"schedulerChecked": true'
  assert_contains "$status_json" '"nextJsRuntime": {'
  assert_contains "$status_json" '"status": "ok"'
  assert_contains "$status_json" '"mode": "standalone"'
  assert_contains "$status_json" '"reverseProxy": {'
  assert_contains "$status_json" '"status": "not-applicable"'
  assert_not_contains "$status_json" "$manager_root"
}

test_static_service_manager_status "systemd" 39209 "systemd-timer"
test_static_service_manager_status "systemv" 39207 "cron"
test_static_service_manager_status "openrc" 39208 "cron"

BAD_ROOT="$TEST_ROOT/standalone-missing-static"
mkdir -p "$BAD_ROOT/app/.next" "$BAD_ROOT/app/node_modules"
write_file "$BAD_ROOT/app/server.js" "console.log('missing static');"
write_env "$BAD_ROOT/app.env" "$BAD_ROOT" 39201 "standalone" "server.js" "launchd"
expect_failure "standalone missing static preflight" ".next/static" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$BAD_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_failure "standalone missing static runtime layout" ".next/static" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$BAD_ROOT/app.env"
expect_failure "standalone missing static safe status" ".next/static" bash "$REPO_ROOT/scripts/linux/status-node-app.sh" "$BAD_ROOT/app.env" --skip-service-manager-check --skip-port-check --skip-health-check --fail-on-critical

BAD_SHELL_START_ROOT="$TEST_ROOT/standalone-shell-style-start"
mkdir -p "$BAD_SHELL_START_ROOT/app/.next" "$BAD_SHELL_START_ROOT/app/node_modules"
write_file "$BAD_SHELL_START_ROOT/app/node server.js" "console.log('placeholder');"
write_env "$BAD_SHELL_START_ROOT/app.env" "$BAD_SHELL_START_ROOT" 39219 "standalone" "node server.js" "launchd"
expect_failure "standalone shell-style start preflight" "START_SCRIPT must be a single file path" bash "$REPO_ROOT/scripts/linux/test-deployment-preflight.sh" "$BAD_SHELL_START_ROOT/app.env" --skip-reverse-proxy --skip-health-check --skip-service-manager-check
expect_failure "standalone shell-style start runtime layout" "START_SCRIPT must be a single file path" bash "$REPO_ROOT/scripts/linux/test-nextjs-runtime-layout.sh" "$BAD_SHELL_START_ROOT/app.env"

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

test_static_service_manager_status "bsdrc" 39203 "cron"

echo "Unix Next.js support checks OK"
