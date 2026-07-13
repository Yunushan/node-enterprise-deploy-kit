#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${1:-config/linux/app.env}"
shift || true
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

ALLOW_PORT_IN_USE="${ALLOW_PORT_IN_USE:-false}"
SKIP_PACKAGE_IMPORT="${SKIP_PACKAGE_IMPORT:-false}"
SKIP_REVERSE_PROXY="${SKIP_REVERSE_PROXY:-false}"
SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-false}"
SKIP_SERVICE_MANAGER_CHECK="${SKIP_SERVICE_MANAGER_CHECK:-false}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --allow-port-in-use) ALLOW_PORT_IN_USE="true" ;;
    --skip-reverse-proxy) SKIP_REVERSE_PROXY="true" ;;
    --skip-health-check) SKIP_HEALTH_CHECK="true" ;;
    --skip-service-manager-check) SKIP_SERVICE_MANAGER_CHECK="true" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

PLATFORM_FAMILY="$(detect_platform_family)"
APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"
APP_FRAMEWORK_NORMALIZED="$(normalize_name "${APP_FRAMEWORK:-node}")"
DEFAULT_NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
NEXTJS_MINIMUM_NODE_VERSION_EFFECTIVE="${NEXTJS_MINIMUM_NODE_VERSION:-$DEFAULT_NEXTJS_MINIMUM_NODE_VERSION}"

errors=()
warnings=()
add_error() { errors+=("$1"); }
add_warning() { warnings+=("$1"); }
require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    add_error "Missing required config value: $name"
  fi
}
is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}
service_main_pid() {
  local service_manager_normalized
  service_manager_normalized="$(normalize_name "${SERVICE_MANAGER:-systemd}")"
  local service_name="${APP_NAME:-}"
  if [[ "${APP_RUNTIME_NORMALIZED:-node}" == "tomcat" || "${APP_RUNTIME_NORMALIZED:-node}" == "apache-tomcat" ]]; then
    service_name="${TOMCAT_SERVICE:-$service_name}"
  fi
  case "$service_manager_normalized" in
    systemd)
      systemctl show -p MainPID --value "$service_name" 2>/dev/null || true
      ;;
    *)
      echo ""
      ;;
  esac
}
url_host() {
  local url="${1:-}" host
  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  host="${host#[}"
  host="${host%]}"
  printf '%s\n' "$host"
}
is_loopback_host() {
  local host
  host="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "0:0:0:0:0:0:0:1" || "$host" == "::1" || "$host" =~ ^127\. ]]
}
is_sensitive_key_name() {
  [[ "${1:-}" =~ ([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]|[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn][Ss][Tt][Rr][Ii][Nn][Gg]|[Dd][Aa][Tt][Aa][Bb][Aa][Ss][Ee]_[Uu][Rr][Ll]|[Jj][Ww][Tt]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee]) ]]
}
is_base64_aes_key_length() {
  local key="${1:-}" node_bin="${NODE_BIN:-}"
  [[ -n "$key" && -n "$node_bin" && -x "$node_bin" ]] || return 1
  "$node_bin" -e '
const key = process.argv[1] || "";
if (!/^[A-Za-z0-9+/]+={0,2}$/.test(key) || key.length % 4 !== 0) process.exit(2);
const bytes = Buffer.from(key, "base64");
const normalized = bytes.toString("base64").replace(/=+$/, "");
const input = key.replace(/=+$/, "");
if (normalized !== input) process.exit(2);
if (![16, 24, 32].includes(bytes.length)) process.exit(3);
' "$key" >/dev/null 2>&1
}
safe_relative_path() {
  local path="${1//\\//}"
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  IFS='/' read -r -a parts <<< "$path"
  local part
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    [[ "$part" != ".." ]] || return 1
  done
  return 0
}
normalize_relative_path_for_compare() {
  local path="${1//\\//}"
  while [[ "$path" == ./* ]]; do path="${path#./}"; done
  path="${path%/}"
  printf '%s\n' "$path"
}
is_react_framework() {
  case "$(normalize_name "${1:-}")" in
    react|reactjs|react-js) return 0 ;;
    *) return 1 ;;
  esac
}
react_document_root() {
  local root="${REACT_DOCUMENT_ROOT:-build}"
  root="${root//\\//}"
  root="${root#/}"
  root="${root%/}"
  [[ -n "$root" ]] || root="build"
  printf '%s\n' "$root"
}
app_relative_path() {
  local root="${1%/}" relative="${2//\\//}"
  relative="${relative#/}"
  relative="${relative%/}"
  if [[ -z "$relative" || "$relative" == "." ]]; then
    printf '%s\n' "$root"
  else
    printf '%s/%s\n' "$root" "$relative"
  fi
}
is_user_runtime_path() {
  [[ "${1:-}" =~ ^/home/[^/]+/(Desktop|Downloads|Documents)(/|$) || "${1:-}" =~ ^/Users/[^/]+/(Desktop|Downloads|Documents)(/|$) ]]
}
nextjs_start_command_path() {
  local start_script="${START_SCRIPT:-server.js}"
  if [[ "$start_script" = /* ]]; then
    printf '%s\n' "$start_script"
  else
    printf '%s/%s\n' "${APP_DIR%/}" "$start_script"
  fi
}
argument_tokens_contain_next_start() {
  local tokens=()
  read -r -a tokens <<< "${NODE_ARGUMENTS:-}"
  [[ "${#tokens[@]}" -gt 0 && "${tokens[0]}" == "start" ]]
}
next_start_hostname_argument() {
  local tokens=() i token
  read -r -a tokens <<< "${NODE_ARGUMENTS:-}"
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    token="${tokens[$i]}"
    case "$token" in
      -H|--hostname)
        if (( i + 1 < ${#tokens[@]} )); then printf '%s\n' "${tokens[$((i + 1))]}"; fi
        return 0
        ;;
      --hostname=*)
        printf '%s\n' "${token#--hostname=}"
        return 0
        ;;
      -H=*)
        printf '%s\n' "${token#-H=}"
        return 0
        ;;
    esac
  done
}
node_runtime_version() {
  local node_bin="${NODE_BIN:-node}" output
  output="$("$node_bin" --version 2>/dev/null | head -n 1 || true)"
  printf '%s\n' "$output"
}
validate_nextjs_node_version() {
  local minimum="$NEXTJS_MINIMUM_NODE_VERSION_EFFECTIVE" node_version rc
  if ! semver_components "$minimum" >/dev/null; then
    add_error "NEXTJS_MINIMUM_NODE_VERSION must be a semantic version like 20.9.0."
    return 0
  fi
  if [[ -z "${NODE_BIN:-}" ]]; then
    add_error "APP_FRAMEWORK=nextjs requires NODE_BIN so preflight can verify the Node.js version."
    return 0
  fi
  node_version="$(node_runtime_version)"
  if [[ -z "$node_version" ]]; then
    add_error "Next.js requires Node.js >= $minimum, but NODE_BIN did not return a version with --version: ${NODE_BIN:-node}"
    return 0
  fi
  if semver_at_least "$node_version" "$minimum"; then
    return 0
  fi
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    add_error "Next.js requires Node.js >= $minimum, but NODE_BIN returned an unrecognized version: $node_version"
  else
    add_error "Next.js requires Node.js >= $minimum; configured NODE_BIN reports $node_version."
  fi
}
validate_nextjs_layout() {
  case "$APP_FRAMEWORK_NORMALIZED" in
    next|nextjs|next-js) ;;
    *) return 0 ;;
  esac

  if [[ "$APP_RUNTIME_NORMALIZED" != "node" ]]; then
    add_error "APP_FRAMEWORK=nextjs requires APP_RUNTIME=node."
    return 0
  fi
  validate_nextjs_node_version
  if is_true "${NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY:-false}"; then
    if [[ -z "${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY:-}" ]]; then
      add_error "NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY=true, but NEXT_SERVER_ACTIONS_ENCRYPTION_KEY is missing. Put the value in target-local private config, not committed example config."
    elif ! is_base64_aes_key_length "$NEXT_SERVER_ACTIONS_ENCRYPTION_KEY"; then
      add_error "NEXT_SERVER_ACTIONS_ENCRYPTION_KEY must be base64-encoded with a valid AES key length of 16, 24, or 32 bytes."
    fi
  fi
  if is_true "${NEXTJS_REQUIRE_DEPLOYMENT_ID:-false}"; then
    if [[ -z "${NEXT_DEPLOYMENT_ID:-}" ]]; then
      add_error "NEXTJS_REQUIRE_DEPLOYMENT_ID=true, but NEXT_DEPLOYMENT_ID is missing. Put the deployment ID in target-local private config or set it during build."
    elif [[ "$NEXT_DEPLOYMENT_ID" =~ [[:space:]] ]]; then
      add_error "NEXT_DEPLOYMENT_ID must not contain whitespace."
    fi
  fi
  if [[ -z "${APP_DIR:-}" || ! -d "${APP_DIR:-}" ]]; then
    return 0
  fi

  local mode hostname_argument start_path
  mode="$(normalize_name "${NEXTJS_DEPLOYMENT_MODE:-standalone}")"
  case "$mode" in
    standalone)
      if [[ "${START_SCRIPT:-server.js}" == *" "* ]]; then
        add_error "START_SCRIPT must be a single file path for Next.js standalone validation. Put script arguments in NODE_ARGUMENTS."
        return 0
      fi
      if [[ "${START_SCRIPT:-server.js}" != /* ]] && ! safe_relative_path "${START_SCRIPT:-server.js}"; then
        add_error "START_SCRIPT must be a safe relative file path for Next.js standalone validation."
        return 0
      fi

      local start_path standalone_root start_name
      start_path="$(nextjs_start_command_path)"
      standalone_root="$(dirname "$start_path")"
      start_name="$(basename "$start_path")"
      if [[ "$start_name" != "server.js" ]]; then
        add_warning "Next.js standalone deployments normally start the generated server.js file."
      fi
      [[ -d "$standalone_root/.next" ]] || add_error "Next.js standalone runtime root is missing .next directory: $standalone_root"
      [[ -f "$standalone_root/.next/BUILD_ID" ]] || add_error "Next.js standalone runtime root is missing .next/BUILD_ID. Keep BUILD_ID with the deployed artifact so status evidence can identify the running build."
      if is_true "${NEXTJS_REQUIRE_STATIC_ASSETS:-true}" && [[ ! -d "$standalone_root/.next/static" ]]; then
        add_error "Next.js standalone runtime root is missing .next/static. Copy .next/static into the standalone .next directory before deployment."
      fi
      if is_true "${NEXTJS_REQUIRE_PUBLIC_DIR:-false}" && [[ ! -d "$standalone_root/public" ]]; then
        add_error "Next.js standalone runtime root is missing public directory, but NEXTJS_REQUIRE_PUBLIC_DIR=true."
      fi
      [[ -f "$standalone_root/node_modules/next/package.json" ]] || add_error "Next.js standalone runtime root is missing node_modules/next/package.json. Keep Next.js package metadata with the deployed artifact so status evidence can prove the installed Next.js version."
      ;;
    next-start)
      if [[ "${START_SCRIPT:-}" == *" "* ]]; then
        add_error "START_SCRIPT must be a single file path for Next.js next-start validation."
      elif [[ "${START_SCRIPT:-}" != /* ]] && ! safe_relative_path "${START_SCRIPT:-}"; then
        add_error "START_SCRIPT must be a safe relative file path for Next.js next-start validation."
      else
        start_path="$(nextjs_start_command_path)"
        [[ -f "$start_path" ]] || add_error "Next.js next-start START_SCRIPT file was not found: $start_path"
        [[ -f "${APP_DIR%/}/node_modules/next/package.json" ]] || add_error "Next.js next-start mode is missing node_modules/next/package.json under APP_DIR."
        expected_next_start_script="node_modules/next/dist/bin/next"
        expected_start_path="${APP_DIR%/}/$expected_next_start_script"
        if [[ "${START_SCRIPT:-}" = /* ]]; then
          [[ "$start_path" == "$expected_start_path" ]] ||
            add_error "Next.js next-start START_SCRIPT must point to node_modules/next/dist/bin/next under APP_DIR."
        else
          [[ "$(normalize_relative_path_for_compare "${START_SCRIPT:-}")" == "$expected_next_start_script" ]] ||
            add_error "Next.js next-start START_SCRIPT must point to node_modules/next/dist/bin/next under APP_DIR."
        fi
      fi
      if ! argument_tokens_contain_next_start; then
        add_error "Next.js next-start mode requires NODE_ARGUMENTS to start with 'start'. Example: start -H ${BIND_ADDRESS:-127.0.0.1}"
      fi
      hostname_argument="$(next_start_hostname_argument)"
      if [[ -z "$hostname_argument" ]]; then
        add_error "Next.js next-start mode requires NODE_ARGUMENTS to include '-H ${BIND_ADDRESS:-127.0.0.1}' or '--hostname ${BIND_ADDRESS:-127.0.0.1}' so next start binds to BIND_ADDRESS."
      elif [[ "$hostname_argument" != "${BIND_ADDRESS:-127.0.0.1}" ]]; then
        add_error "Next.js next-start hostname argument '$hostname_argument' must match BIND_ADDRESS '${BIND_ADDRESS:-127.0.0.1}'."
      fi
      [[ -f "$APP_DIR/package.json" ]] || add_error "Next.js next-start mode requires package.json under APP_DIR."
      [[ -d "$APP_DIR/.next" ]] || add_error "Next.js next-start mode requires a built .next directory under APP_DIR."
      [[ -f "$APP_DIR/.next/BUILD_ID" ]] || add_error "Next.js next-start mode requires .next/BUILD_ID under APP_DIR so status evidence can identify the running build."
      [[ -d "$APP_DIR/node_modules/next" ]] || add_error "Next.js next-start mode requires node_modules/next under APP_DIR."
      ;;
    *)
      add_error "NEXTJS_DEPLOYMENT_MODE must be standalone or next-start."
      ;;
  esac
}
validate_react_layout() {
  is_react_framework "$APP_FRAMEWORK_NORMALIZED" || return 0

  if [[ "$APP_RUNTIME_NORMALIZED" != "node" ]]; then
    add_error "APP_FRAMEWORK=reactjs requires APP_RUNTIME=node."
    return 0
  fi

  local document_root react_root
  document_root="$(react_document_root)"
  if ! safe_relative_path "$document_root"; then
    add_error "REACT_DOCUMENT_ROOT must be a safe relative directory path."
    return 0
  fi

  if [[ -z "${APP_DIR:-}" || ! -d "${APP_DIR:-}" ]]; then
    return 0
  fi

  react_root="$(app_relative_path "$APP_DIR" "$document_root")"
  [[ -f "$react_root/index.html" ]] || add_error "React deployment root is missing index.html: $react_root/index.html"
  if [[ ! -d "$react_root/static" && ! -d "$react_root/assets" ]]; then
    add_warning "React deployment root has no static or assets directory. This can be valid for tiny apps, but verify the built artifact contains browser assets."
  fi
}

for key in APP_NAME APP_DISPLAY_NAME APP_PORT BIND_ADDRESS HEALTH_URL LOG_DIR SERVICE_MANAGER REVERSE_PROXY; do
  require_value "$key"
done

case "$APP_RUNTIME_NORMALIZED" in
  node)
    for key in APP_DIR NODE_BIN START_SCRIPT SERVICE_USER SERVICE_GROUP ENV_FILE; do
      require_value "$key"
    done
    ;;
  tomcat|apache-tomcat)
    for key in TOMCAT_WAR_FILE TOMCAT_WEBAPPS_DIR TOMCAT_SERVICE TOMCAT_CONTEXT_PATH; do
      require_value "$key"
    done
    ;;
  *)
    add_error "Unsupported APP_RUNTIME: ${APP_RUNTIME:-node}. Use node or tomcat."
    ;;
esac

if [[ -n "${APP_NAME:-}" && ! "$APP_NAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  add_error "APP_NAME should contain only letters, numbers, dot, underscore, or dash."
fi
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME:-app}}"

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${NODE_BIN:-}" && ! -x "$NODE_BIN" ]]; then
  add_error "NODE_BIN not found or not executable: $NODE_BIN"
fi
if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${NODE_BIN:-}" && "$NODE_BIN" != /* ]]; then
  add_warning "NODE_BIN is not an absolute path. Use an explicit trusted Node.js path in production."
fi

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${APP_DIR:-}" && ! -d "$APP_DIR" ]]; then
  if [[ -n "${PACKAGE_PATH:-}" ]] && ! is_true "$SKIP_PACKAGE_IMPORT"; then
    add_warning "APP_DIR does not exist yet, but PACKAGE_PATH is configured. Package import should create it before service install."
  else
    add_error "APP_DIR not found: $APP_DIR"
  fi
fi
for path_name in APP_DIR LOG_DIR ENV_FILE BACKUP_DIR HEALTHCHECK_STATE_DIR; do
  if is_user_runtime_path "${!path_name:-}"; then
    add_warning "$path_name is under a user desktop/downloads/documents path. Use a service-owned production directory."
  fi
done

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${PREPARATION_ENV_FILE:-}" ]]; then
  if [[ "$PREPARATION_ENV_FILE" != /* ]]; then
    add_error "PREPARATION_ENV_FILE must be an absolute target-local path."
  elif [[ ! -f "$PREPARATION_ENV_FILE" ]]; then
    add_error "PREPARATION_ENV_FILE was not found: $PREPARATION_ENV_FILE"
  else
    preparation_line_number=0
    while IFS= read -r preparation_line || [[ -n "$preparation_line" ]]; do
      preparation_line_number=$((preparation_line_number + 1))
      preparation_line="${preparation_line%$'\r'}"
      [[ -z "$preparation_line" || "$preparation_line" == \#* ]] && continue
      if [[ "$preparation_line" != *=* ]]; then
        add_error "PREPARATION_ENV_FILE line $preparation_line_number must use NAME=value syntax."
        continue
      fi
      preparation_key="${preparation_line%%=*}"
      if [[ ! "$preparation_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        add_error "PREPARATION_ENV_FILE line $preparation_line_number has an invalid environment variable name."
      fi
    done < "$PREPARATION_ENV_FILE"
  fi
fi

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${APP_DIR:-}" && -d "$APP_DIR" && -n "${START_SCRIPT:-}" ]]; then
  if [[ "$START_SCRIPT" = /* ]]; then
    [[ -f "$START_SCRIPT" ]] || add_error "START_SCRIPT file not found: $START_SCRIPT"
  elif [[ "$START_SCRIPT" != *" "* ]]; then
    [[ -f "$APP_DIR/$START_SCRIPT" ]] || add_error "START_SCRIPT file not found under APP_DIR: $APP_DIR/$START_SCRIPT"
  fi
fi

validate_nextjs_layout
validate_react_layout

if [[ -n "${PACKAGE_PATH:-}" ]] && ! is_true "$SKIP_PACKAGE_IMPORT"; then
  if [[ "$APP_RUNTIME_NORMALIZED" != "node" ]]; then
    add_error "PACKAGE_PATH imports are for APP_RUNTIME=node. Use TOMCAT_WAR_FILE for Tomcat deployments."
  fi
  case "$PACKAGE_PATH" in
    *.zip|*.tar|*.tar.gz|*.tgz) ;;
    *.rar|*.7z) add_error "PACKAGE_PATH format is intentionally unsupported: use .zip, .tar.gz, .tgz, or .tar. .rar/.7z need external tooling." ;;
    *) add_error "Unsupported PACKAGE_PATH format. Use .zip, .tar.gz, .tgz, or .tar." ;;
  esac
  if [[ "$PACKAGE_PATH" = /* ]]; then
    package_candidate="$PACKAGE_PATH"
  else
    package_candidate="$(dirname "$CONFIG_FILE")/$PACKAGE_PATH"
  fi
  [[ -f "$package_candidate" ]] || add_warning "PACKAGE_PATH does not exist yet on this host: $package_candidate"
  case "${PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR:-true}" in
    true|false|TRUE|FALSE|True|False|1|0|yes|no|YES|NO|Yes|No) ;;
    *) add_warning "PACKAGE_STRIP_SINGLE_TOP_LEVEL_DIR should be true or false." ;;
  esac
  while IFS= read -r expected_file; do
    [[ -z "$expected_file" ]] && continue
    if ! safe_relative_path "$expected_file"; then
      add_error "PACKAGE_EXPECTED_FILES contains an unsafe relative path: $expected_file"
    fi
  done < <(runtime_env_key_list "${PACKAGE_EXPECTED_FILES:-${START_SCRIPT:-server.js}}")
fi

if ! is_integer "${APP_PORT:-}" || [[ "${APP_PORT:-0}" -lt 1 || "${APP_PORT:-0}" -gt 65535 ]]; then
  add_error "APP_PORT must be an integer between 1 and 65535."
fi

if [[ -n "${HEALTH_URL:-}" ]]; then
  case "$HEALTH_URL" in
    http://*|https://*) ;;
    *) add_error "HEALTH_URL must start with http:// or https://" ;;
  esac
fi

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && "${SERVICE_USER:-}" == "root" ]]; then
  add_warning "SERVICE_USER is root. Use a dedicated non-root service user for production."
fi
if [[ "$APP_RUNTIME_NORMALIZED" == "node" && "${SERVICE_GROUP:-}" == "root" ]]; then
  add_warning "SERVICE_GROUP is root. Use a dedicated non-root service group for production."
fi
if [[ "${INSTALL_COMMAND:-}" =~ npm[[:space:]]+install($|[[:space:]]) ]]; then
  add_warning "INSTALL_COMMAND uses npm install. Prefer npm ci --omit=dev or deploy a built artifact for deterministic production installs."
fi
secret_like_runtime_keys=()
while IFS= read -r runtime_key; do
  if is_sensitive_key_name "$runtime_key"; then
    secret_like_runtime_keys+=("$runtime_key")
  fi
done < <(runtime_env_key_list "${RUNTIME_ENV_KEYS:-}")
if [[ "${#secret_like_runtime_keys[@]}" -gt 0 ]]; then
  add_warning "RUNTIME_ENV_KEYS contains secret-like key name(s): ${secret_like_runtime_keys[*]}. Keep values out of committed config and prefer a secret manager or target-local private env file."
fi

SERVICE_MANAGER_NORMALIZED="$(normalize_name "${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}")"
case "$SERVICE_MANAGER_NORMALIZED" in
  systemd)
    if ! is_true "$SKIP_SERVICE_MANAGER_CHECK"; then
      command -v systemctl >/dev/null 2>&1 || add_error "SERVICE_MANAGER=systemd but systemctl was not found."
    fi
    ;;
  systemv|sysv|sysvinit|initd|init-d)
    if ! is_true "$SKIP_SERVICE_MANAGER_CHECK" && ! command -v service >/dev/null 2>&1 && [[ ! -x "/etc/init.d/${APP_NAME:-}" ]]; then
      add_warning "System V selected, but service command/init script is not currently available."
    fi
    ;;
  openrc)
    if ! is_true "$SKIP_SERVICE_MANAGER_CHECK"; then
      command -v rc-service >/dev/null 2>&1 || add_error "SERVICE_MANAGER=openrc but rc-service was not found."
      command -v rc-update >/dev/null 2>&1 || add_error "SERVICE_MANAGER=openrc but rc-update was not found."
    fi
    ;;
  launchd)
    if ! is_true "$SKIP_SERVICE_MANAGER_CHECK"; then
      command -v launchctl >/dev/null 2>&1 || add_error "SERVICE_MANAGER=launchd but launchctl was not found."
    fi
    [[ "$PLATFORM_FAMILY" == "macos" ]] || add_warning "SERVICE_MANAGER=launchd is normally used on macOS."
    ;;
  bsdrc|bsd-rc|rcd|rc.d)
    [[ "$PLATFORM_FAMILY" =~ ^(freebsd|openbsd|netbsd)$ ]] || add_warning "SERVICE_MANAGER=bsdrc is normally used on BSD systems."
    ;;
  *)
    add_error "Unsupported SERVICE_MANAGER: ${SERVICE_MANAGER:-}. Use systemd, systemv, openrc, launchd, or bsdrc."
    ;;
esac

if ! is_true "$SKIP_REVERSE_PROXY"; then
  REVERSE_PROXY_NORMALIZED="$(normalize_name "${REVERSE_PROXY:-none}")"
  proxy_listen_port_value="$(proxy_listen_port)"
  forwarded_proto_value="$(proxy_forwarded_proto)"
  forwarded_port_value="$(proxy_forwarded_port)"
  if ! is_integer "$proxy_listen_port_value" || [[ "$proxy_listen_port_value" -lt 1 || "$proxy_listen_port_value" -gt 65535 ]]; then
    add_error "PROXY_LISTEN_PORT must be an integer between 1 and 65535."
  fi
  if ! is_integer "$forwarded_port_value" || [[ "$forwarded_port_value" -lt 1 || "$forwarded_port_value" -gt 65535 ]]; then
    add_error "FORWARDED_PORT/PUBLIC_PORT must resolve to an integer between 1 and 65535."
  fi
  case "$forwarded_proto_value" in
    http|https) ;;
    *) add_error "FORWARDED_PROTO must be http or https." ;;
  esac
  if is_true "${TLS_ENABLED:-false}" && [[ "$forwarded_proto_value" != "https" ]]; then
    add_warning "TLS_ENABLED=true but forwarded protocol resolves to '$forwarded_proto_value'. Use FORWARDED_PROTO=https for upstream/public TLS."
  fi
  if [[ "$proxy_listen_port_value" == "443" ]]; then
    add_warning "PROXY_LISTEN_PORT=443, but Linux proxy templates do not configure certificate files. Confirm TLS is configured manually or terminate TLS upstream."
  fi
  if [[ "$APP_RUNTIME_NORMALIZED" == "node" && "$REVERSE_PROXY_NORMALIZED" != "none" && "$REVERSE_PROXY_NORMALIZED" != "" && -n "${BIND_ADDRESS:-}" ]] && ! is_loopback_host "$BIND_ADDRESS"; then
    add_warning "BIND_ADDRESS is '$BIND_ADDRESS' while REVERSE_PROXY is '${REVERSE_PROXY:-}'. Bind the app to 127.0.0.1 unless direct exposure is intentional."
  fi
  if [[ "$REVERSE_PROXY_NORMALIZED" != "none" && "$REVERSE_PROXY_NORMALIZED" != "" && -n "${HEALTH_URL:-}" ]] && ! is_loopback_host "$(url_host "$HEALTH_URL")"; then
    add_warning "HEALTH_URL host is '$(url_host "$HEALTH_URL")'. For reverse-proxy deployments, health checks should normally target localhost/127.0.0.1."
  fi
  if [[ "$REVERSE_PROXY_NORMALIZED" != "none" && "$REVERSE_PROXY_NORMALIZED" != "" ]] && ! is_true "${TLS_ENABLED:-false}"; then
    add_warning "TLS_ENABLED is false while a reverse proxy is configured. Use TLS at the proxy or a documented upstream load balancer in production."
  fi
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx)
      command -v nginx >/dev/null 2>&1 || add_error "REVERSE_PROXY=nginx but nginx was not found. Install nginx or run scripts/linux/install-dependencies.sh before deployment."
      [[ -n "${NGINX_SITE_NAME:-}" ]] || add_warning "NGINX_SITE_NAME is empty; scripts may use an empty config filename."
      ;;
    apache|httpd)
      if ! command -v apache2ctl >/dev/null 2>&1 && ! command -v httpd >/dev/null 2>&1; then
        add_error "REVERSE_PROXY=apache but apache2ctl/httpd was not found. Install Apache/httpd or run scripts/linux/install-dependencies.sh before deployment."
      fi
      ;;
    haproxy)
      command -v haproxy >/dev/null 2>&1 || add_error "REVERSE_PROXY=haproxy but haproxy was not found. Install haproxy or run scripts/linux/install-dependencies.sh before deployment."
      case "${HAPROXY_ALLOW_MAIN_CONFIG_REPLACE:-false}" in
        true|false|TRUE|FALSE|True|False|1|0|yes|no|YES|NO|Yes|No) ;;
        *) add_warning "HAPROXY_ALLOW_MAIN_CONFIG_REPLACE should be true or false." ;;
      esac
      ;;
    traefik)
      command -v traefik >/dev/null 2>&1 || add_error "REVERSE_PROXY=traefik but traefik was not found. Install traefik or run scripts/linux/install-dependencies.sh before deployment."
      [[ -n "${TRAEFIK_DYNAMIC_DIR:-}" || -n "${TRAEFIK_DYNAMIC_FILE:-}" ]] || add_warning "TRAEFIK_DYNAMIC_DIR/TRAEFIK_DYNAMIC_FILE is empty; using /etc/traefik/dynamic."
      ;;
    none|"") ;;
    *)
      add_error "Unsupported REVERSE_PROXY: ${REVERSE_PROXY:-}. Use nginx, apache, haproxy, traefik, or none."
      ;;
  esac
fi

if [[ "$APP_RUNTIME_NORMALIZED" =~ ^(tomcat|apache-tomcat)$ ]]; then
  [[ -f "${TOMCAT_WAR_FILE:-}" ]] || add_error "TOMCAT_WAR_FILE not found: ${TOMCAT_WAR_FILE:-}"
  [[ -d "${TOMCAT_WEBAPPS_DIR:-}" ]] || add_warning "TOMCAT_WEBAPPS_DIR does not exist yet: ${TOMCAT_WEBAPPS_DIR:-}"
fi

if ! is_true "$SKIP_HEALTH_CHECK"; then
  case "$SERVICE_MANAGER_NORMALIZED" in
    systemd)
      command -v systemctl >/dev/null 2>&1 || add_error "Healthcheck scheduler requires systemctl for SERVICE_MANAGER=systemd."
      ;;
    launchd)
      command -v launchctl >/dev/null 2>&1 || add_error "Healthcheck scheduler requires launchctl for SERVICE_MANAGER=launchd."
      ;;
    systemv|sysv|sysvinit|initd|init-d|openrc|bsdrc|bsd-rc|rcd|rc.d)
      command -v crontab >/dev/null 2>&1 || add_error "Healthcheck scheduler requires crontab for SERVICE_MANAGER=${SERVICE_MANAGER:-}."
      ;;
  esac
  if [[ -n "${LOG_DIR:-}" ]]; then
    log_dir_normalized="${LOG_DIR%/}"
    healthcheck_state_dir_normalized="${HEALTHCHECK_STATE_DIR%/}"
    if [[ "$healthcheck_state_dir_normalized" == "$log_dir_normalized" || "$healthcheck_state_dir_normalized" == "$log_dir_normalized"/* ]]; then
      add_error "HEALTHCHECK_STATE_DIR must not be inside LOG_DIR because healthcheck state is root-owned control data."
    fi
  fi
  for value_name in HEALTHCHECK_FAILURE_THRESHOLD HEALTHCHECK_RESTART_COOLDOWN HEALTHCHECK_TIMEOUT; do
    if [[ -n "${!value_name:-}" ]] && ! is_integer "${!value_name}"; then
      add_warning "$value_name should be an integer."
    fi
  done
fi

if is_integer "${APP_PORT:-}" && command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$APP_PORT )" 2>/dev/null | tail -n +2 | grep -q .; then
    main_pid="$(service_main_pid)"
    if is_true "$ALLOW_PORT_IN_USE"; then
      add_warning "Port $APP_PORT is already listening."
    elif [[ -n "$main_pid" && "$main_pid" != "0" ]] && ss -ltnp "( sport = :$APP_PORT )" 2>/dev/null | grep -q "pid=$main_pid,"; then
      add_warning "Port $APP_PORT is already listening by the configured systemd service."
    else
      add_error "Port $APP_PORT is already listening. Stop the conflict or pass --allow-port-in-use for intentional updates."
    fi
  fi
fi

echo "Preflight checked: ${APP_NAME:-unknown}"

if [[ "${#warnings[@]}" -gt 0 ]]; then
  echo ""
  echo "Warnings"
  for warning in "${warnings[@]}"; do echo "WARNING: $warning"; done
fi

if [[ "${#errors[@]}" -gt 0 ]]; then
  echo ""
  echo "Errors" >&2
  for error in "${errors[@]}"; do echo "ERROR: $error" >&2; done
  exit 1
fi

echo "Preflight passed."
