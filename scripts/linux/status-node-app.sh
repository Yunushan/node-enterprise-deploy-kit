#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/status-node-app.sh [config.env] [options]

Safe Unix-like host status check for a deployed Node.js / Next.js app.

Options:
  --minimum-uptime-hours N       Warn if known service process uptime is below N.
  --health-timeout N             HTTP health timeout in seconds.
  --skip-service-manager-check   Skip service-manager status checks.
  --skip-port-check              Skip configured port listener checks.
  --skip-health-check            Skip HTTP health probe.
  --json-output PATH             Write safe machine-readable status evidence to PATH.
  --fail-on-critical             Exit 2 when critical findings exist.
  --fail-on-warning              Exit 3 when warnings exist and no critical findings exist.
  --fail-on-warnings             Alias for --fail-on-warning.
  -h, --help                     Show this help.
USAGE
}

CONFIG_FILE=""
MINIMUM_UPTIME_HOURS="0"
HEALTH_TIMEOUT_SECONDS=""
SKIP_SERVICE_MANAGER_CHECK="false"
SKIP_PORT_CHECK="false"
SKIP_HEALTH_CHECK="false"
JSON_OUTPUT=""
FAIL_ON_CRITICAL="false"
FAIL_ON_WARNING="false"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --minimum-uptime-hours)
      MINIMUM_UPTIME_HOURS="${2:?--minimum-uptime-hours requires a value}"
      shift 2
      ;;
    --health-timeout)
      HEALTH_TIMEOUT_SECONDS="${2:?--health-timeout requires a value}"
      shift 2
      ;;
    --skip-service-manager-check)
      SKIP_SERVICE_MANAGER_CHECK="true"
      shift
      ;;
    --skip-port-check)
      SKIP_PORT_CHECK="true"
      shift
      ;;
    --skip-health-check)
      SKIP_HEALTH_CHECK="true"
      shift
      ;;
    --json-output)
      JSON_OUTPUT="${2:?--json-output requires a value}"
      shift 2
      ;;
    --fail-on-critical)
      FAIL_ON_CRITICAL="true"
      shift
      ;;
    --fail-on-warning|--fail-on-warnings)
      FAIL_ON_WARNING="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${CONFIG_FILE:-config/linux/app.env}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"
APP_FRAMEWORK_NORMALIZED="$(normalize_name "${APP_FRAMEWORK:-node}")"
NEXTJS_DEPLOYMENT_MODE_NORMALIZED="$(normalize_name "${NEXTJS_DEPLOYMENT_MODE:-standalone}")"
SERVICE_MANAGER_NORMALIZED="$(normalize_name "${SERVICE_MANAGER:-$(default_service_manager "$(detect_platform_family)")}")"
REVERSE_PROXY_NORMALIZED="$(normalize_name "${REVERSE_PROXY:-none}")"
SERVICE_NAME="${SERVICE_NAME:-${APP_NAME:-}}"
if [[ "$APP_RUNTIME_NORMALIZED" == "tomcat" || "$APP_RUNTIME_NORMALIZED" == "apache-tomcat" ]]; then
  SERVICE_NAME="${TOMCAT_SERVICE:-$SERVICE_NAME}"
fi
RUNNER_SCRIPT="${RUNNER_SCRIPT:-/usr/local/sbin/${APP_NAME}-runner.sh}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-${HEALTHCHECK_TIMEOUT:-10}}"
HEALTHCHECK_STATE_DIR="${HEALTHCHECK_STATE_DIR:-/var/lib/node-enterprise-deploy-kit/${APP_NAME:-app}}"
HEALTHCHECK_STATE_FILE="$HEALTHCHECK_STATE_DIR/healthcheck.state"
HEALTHCHECK_FAILURE_THRESHOLD="${HEALTHCHECK_FAILURE_THRESHOLD:-2}"
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-60}"
SERVICE_ACTIVE_STATUS="unknown"
SERVICE_ENABLED_STATUS="unknown"
NEXTJS_LAYOUT_APPLICABLE="false"
NEXTJS_LAYOUT_STATUS="not-applicable"
NEXTJS_RUNTIME_ROOT=""
NEXT_START_SCRIPT_IS_EXPECTED_CLI=""
DEFAULT_NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
NEXTJS_MINIMUM_NODE_VERSION_EFFECTIVE="${NEXTJS_MINIMUM_NODE_VERSION:-$DEFAULT_NEXTJS_MINIMUM_NODE_VERSION}"
NEXTJS_NODE_VERSION_SATISFIED="false"
REVERSE_PROXY_APPLICABLE="false"
REVERSE_PROXY_STATUS="not-applicable"
REVERSE_PROXY_PROBE_URL=""
REVERSE_PROXY_STATUS_CODE=""
REVERSE_PROXY_RESPONSE_SECONDS=""
REVERSE_PROXY_CONFIG_APPLICABLE="false"
REVERSE_PROXY_CONFIG_PATH_NAME=""
REVERSE_PROXY_CONFIG_DIR_NAME=""
REVERSE_PROXY_CONFIG_EXISTS="false"
REVERSE_PROXY_CONFIG_MANAGED_MARKER_FOUND="false"
REVERSE_PROXY_CONFIG_EXPECTED_PORT=""
PORT_CHECKED="false"
PORT_LISTENING="false"
PORT_OWNER_READABLE="false"
PORT_OWNER_PROCESS_COUNT="0"
PORT_OWNED_BY_SERVICE="false"
PORT_SERVICE_PID_KNOWN="false"
HEALTH_CHECKED="false"
HEALTH_STATUS="not-checked"
HEALTH_STATUS_CODE=""
HEALTH_RESPONSE_SECONDS=""
HEALTH_PROBE_URL=""
HOST_UPTIME_SECONDS=""
SERVICE_UPTIME_SECONDS=""
UPTIME_MINIMUM_SATISFIED=""
SERVICE_START_KNOWN="false"
SERVICE_DEFINITION_CHECKED="false"
SERVICE_DEFINITION_MANAGER="$SERVICE_MANAGER_NORMALIZED"
SERVICE_DEFINITION_SOURCE="not-checked"
SERVICE_DEFINITION_EXISTS="false"
SERVICE_DEFINITION_NODE_EXE_MATCHES_CONFIG="false"
SERVICE_DEFINITION_WORKING_DIRECTORY_MATCHES_CONFIG="false"
SERVICE_DEFINITION_ARGUMENTS_MATCH_CONFIG="false"
SERVICE_DEFINITION_RUNNER_SCRIPT_MATCHES_CONFIG="false"
HEALTH_MONITOR_STATUS="unknown"
HEALTH_MONITOR_SCHEDULED="false"
HEALTH_MONITOR_SCHEDULE_TYPE="state-log"
case "$SERVICE_MANAGER_NORMALIZED" in
  systemd)
    HEALTH_MONITOR_SCHEDULE_TYPE="systemd-timer"
    ;;
  launchd)
    HEALTH_MONITOR_SCHEDULE_TYPE="launchd-timer"
    ;;
  systemv|sysv|sysvinit|initd|init-d|openrc|bsdrc|bsd-rc|rcd|rc.d)
    HEALTH_MONITOR_SCHEDULE_TYPE="cron"
    ;;
esac
HEALTH_MONITOR_SCHEDULER_CHECKED="false"
HEALTH_MONITOR_SCHEDULER_EXISTS="false"
HEALTH_MONITOR_SCHEDULER_ACTIVE="false"
HEALTH_MONITOR_SCHEDULER_ENABLED="false"
HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS="unknown"
HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS="unknown"
HEALTH_MONITOR_STATE_EXISTS="false"
HEALTH_MONITOR_CONSECUTIVE_FAILURES=""
HEALTH_MONITOR_LAST_SUCCESS_AGE_SECONDS=""
HEALTH_MONITOR_LAST_SUCCESS_FRESH="false"
HEALTH_MONITOR_LOG_EXISTS="false"
HEALTH_MONITOR_LOG_FAILURE_COUNT=""
HEALTH_MONITOR_LOG_RESTART_COUNT=""
DEPLOYMENT_IDENTITY_STATUS="unknown"
DEPLOYMENT_IDENTITY_APP_DIR_NAME=""
DEPLOYMENT_IDENTITY_DEPLOYMENT_ID=""
DEPLOYMENT_IDENTITY_NEXT_BUILD_ID=""
DEPLOYMENT_IDENTITY_MANIFEST_EXISTS="false"
DEPLOYMENT_IDENTITY_MANIFEST_SCHEMA=""
DEPLOYMENT_IDENTITY_PACKAGE_NAME=""
DEPLOYMENT_IDENTITY_PACKAGE_SHA256=""
DEPLOYMENT_IDENTITY_PACKAGE_IMPORTED_AT_UTC=""
DEPLOYMENT_IDENTITY_MANIFEST_NEXT_BUILD_ID=""
NODE_RUNTIME_VERSION=""
NEXT_PACKAGE_VERSION=""

findings=()
add_finding() {
  findings+=("$1|$2")
}
add_critical() { add_finding "Critical" "$1"; }
add_warning() { add_finding "Warning" "$1"; }

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

if ! is_integer "$HEALTHCHECK_FAILURE_THRESHOLD" || [[ "$HEALTHCHECK_FAILURE_THRESHOLD" -lt 1 ]]; then
  HEALTHCHECK_FAILURE_THRESHOLD="2"
fi
if ! is_integer "$HEALTHCHECK_INTERVAL" || [[ "$HEALTHCHECK_INTERVAL" -lt 1 ]]; then
  HEALTHCHECK_INTERVAL="60"
fi

safe_url() {
  local url="${1:-}"
  url="${url%%#*}"
  url="${url%%\?*}"
  printf '%s\n' "$url" | sed -E 's#(https?://)[^/@]+@#\1[redacted]@#'
}

safe_path_name() {
  local path="${1:-}"
  [[ -n "$path" ]] || {
    echo ""
    return
  }
  basename "$path" 2>/dev/null || echo ""
}

safe_evidence_text() {
  local text="${1:-}" path config_dir
  config_dir="$(dirname "${CONFIG_FILE:-.}" 2>/dev/null || echo "")"
  for path in "${APP_DIR:-}" "${CONFIG_FILE:-}" "$config_dir" "${LOG_DIR:-}" "${BACKUP_DIR:-}" "${HEALTHCHECK_STATE_DIR:-}"; do
    [[ -n "$path" && "$path" != "/" ]] || continue
    text="${text//$path/<path>}"
  done
  printf '%s\n' "$text" |
    sed -E 's#(^|[[:space:]])/[[:alnum:]_.@%+=:,/-]+#\1<path>#g; s#[A-Za-z]:\\[^[:space:],;:"<>|]+#<path>#g'
}

safe_runtime_version_text() {
  local value="${1:-}"
  value="${value:0:80}"
  printf '%s' "$value" | sed 's/[^A-Za-z0-9._+:-]/-/g; s/^-*//; s/-*$//'
}

node_runtime_version() {
  local node_bin="${NODE_BIN:-node}" output
  output="$("$node_bin" --version 2>/dev/null || true)"
  safe_runtime_version_text "$output"
}

package_json_version() {
  local package_json="${1:-}"
  [[ -f "$package_json" ]] || return 0
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$package_json" 2>/dev/null |
    head -n 1 |
    while IFS= read -r version; do safe_runtime_version_text "$version"; done
}

next_package_version() {
  local candidate version
  for candidate in \
    "${APP_DIR:-}/node_modules/next/package.json" \
    "${APP_DIR:-}/.next/standalone/node_modules/next/package.json"; do
    version="$(package_json_version "$candidate")"
    if [[ -n "$version" ]]; then
      printf '%s' "$version"
      return 0
    fi
  done
  return 0
}

support_target_id() {
  local kernel os_id os_id_like pretty_lower
  kernel="$(printf '%s' "${KERNEL_NAME:-}" | tr '[:upper:]' '[:lower:]')"
  os_id="$(normalize_name "${OS_RELEASE_ID:-}")"
  os_id_like="$(printf '%s' "${OS_RELEASE_ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
  pretty_lower="$(printf '%s' "${OS_RELEASE_PRETTY_NAME:-}" | tr '[:upper:]' '[:lower:]')"

  case "$kernel" in
    darwin)
      echo "macos"
      return
      ;;
    freebsd|openbsd|netbsd)
      echo "$kernel"
      return
      ;;
  esac

  if [[ "$pretty_lower" == *"centos stream"* ]]; then
    echo "centos-stream"
    return
  fi
  if [[ "$pretty_lower" == *"oracle linux"* ]]; then
    echo "oracle-linux"
    return
  fi
  if [[ "$pretty_lower" == *"linux mint"* ]]; then
    echo "linux-mint"
    return
  fi

  case "$os_id" in
    linuxmint)
      echo "linux-mint"
      ;;
    ol)
      echo "oracle-linux"
      ;;
    redhat|red-hat)
      echo "rhel"
      ;;
    ubuntu|debian|rhel|centos|centos-stream|rocky|almalinux|fedora|alpine|macos|freebsd|openbsd|netbsd)
      echo "$os_id"
      ;;
    *)
      if [[ "$os_id_like" == *"rhel"* || "$os_id_like" == *"redhat"* ]]; then
        echo "rhel"
      elif [[ "$os_id_like" == *"debian"* ]]; then
        echo "debian"
      elif [[ "$kernel" == "linux" ]]; then
        echo "linux"
      else
        echo "$kernel"
      fi
      ;;
  esac
}

default_proxy_health_url() {
  local proxy_port path
  if [[ -n "${PROXY_HEALTH_URL:-}" ]]; then
    printf '%s\n' "$PROXY_HEALTH_URL"
    return
  fi
  case "$REVERSE_PROXY_NORMALIZED" in
    ""|none)
      echo ""
      return
      ;;
  esac
  proxy_port="$(proxy_listen_port)"
  path="${HEALTHCHECK_PATH:-health}"
  path="${path#/}"
  [[ -n "$path" ]] || path="health"
  printf 'http://127.0.0.1:%s/%s\n' "$proxy_port" "$path"
}

reverse_proxy_config_path() {
  local site_name config_dir
  case "$REVERSE_PROXY_NORMALIZED" in
    nginx)
      site_name="${NGINX_SITE_NAME:-${APP_NAME:-}}"
      config_dir="${NGINX_CONFIG_DIR:-}"
      if [[ -z "$config_dir" ]]; then
        case "$PLATFORM_FAMILY" in
          freebsd|openbsd|netbsd)
            config_dir="/usr/local/etc/nginx/conf.d"
            ;;
          macos)
            if [[ -d /opt/homebrew/etc/nginx/servers ]]; then
              config_dir="/opt/homebrew/etc/nginx/servers"
            else
              config_dir="/usr/local/etc/nginx/servers"
            fi
            ;;
          *)
            config_dir="/etc/nginx/conf.d"
            ;;
        esac
      fi
      [[ -n "$site_name" ]] || return 1
      printf '%s/%s.conf\n' "${config_dir%/}" "$site_name"
      ;;
    apache|httpd)
      site_name="${APACHE_SITE_NAME:-${APP_NAME:-}}"
      [[ -n "$site_name" ]] || return 1
      if [[ -n "${APACHE_CONFIG_DIR:-}" ]]; then
        printf '%s/%s.conf\n' "${APACHE_CONFIG_DIR%/}" "$site_name"
      elif [[ -d /etc/apache2/sites-available ]]; then
        printf '/etc/apache2/sites-available/%s.conf\n' "$site_name"
      elif command -v apache2ctl >/dev/null 2>&1; then
        printf '/etc/apache2/conf.d/%s.conf\n' "$site_name"
      elif [[ -d /usr/local/etc/apache24/Includes ]]; then
        printf '/usr/local/etc/apache24/Includes/%s.conf\n' "$site_name"
      elif [[ -d /opt/homebrew/etc/httpd/extra ]]; then
        printf '/opt/homebrew/etc/httpd/extra/%s.conf\n' "$site_name"
      elif [[ -d /usr/local/etc/httpd/extra ]]; then
        printf '/usr/local/etc/httpd/extra/%s.conf\n' "$site_name"
      else
        printf '/etc/httpd/conf.d/%s.conf\n' "$site_name"
      fi
      ;;
    haproxy)
      printf '%s\n' "${HAPROXY_CONFIG_FILE:-/etc/haproxy/haproxy.cfg}"
      ;;
    traefik)
      local dynamic_dir
      dynamic_dir="${TRAEFIK_DYNAMIC_DIR:-/etc/traefik/dynamic}"
      printf '%s\n' "${TRAEFIK_DYNAMIC_FILE:-${dynamic_dir%/}/${APP_NAME:-app}.yml}"
      ;;
    *)
      return 1
      ;;
  esac
}

collect_reverse_proxy_config_evidence() {
  local config_path
  REVERSE_PROXY_CONFIG_APPLICABLE="false"
  REVERSE_PROXY_CONFIG_PATH_NAME=""
  REVERSE_PROXY_CONFIG_DIR_NAME=""
  REVERSE_PROXY_CONFIG_EXISTS="false"
  REVERSE_PROXY_CONFIG_MANAGED_MARKER_FOUND="false"
  REVERSE_PROXY_CONFIG_EXPECTED_PORT="$(proxy_listen_port)"

  case "$REVERSE_PROXY_NORMALIZED" in
    nginx|apache|httpd|haproxy|traefik)
      REVERSE_PROXY_CONFIG_APPLICABLE="true"
      ;;
    *)
      return
      ;;
  esac

  config_path="$(reverse_proxy_config_path 2>/dev/null || true)"
  if [[ -z "$config_path" ]]; then
    add_warning "Could not determine expected reverse proxy config file for mode '$REVERSE_PROXY_NORMALIZED'."
    return
  fi

  REVERSE_PROXY_CONFIG_PATH_NAME="$(safe_path_name "$config_path")"
  REVERSE_PROXY_CONFIG_DIR_NAME="$(safe_path_name "$(dirname "$config_path")")"
  if [[ ! -f "$config_path" ]]; then
    add_warning "Expected reverse proxy config file was not found for mode '$REVERSE_PROXY_NORMALIZED'."
    return
  fi

  REVERSE_PROXY_CONFIG_EXISTS="true"
  if grep -Fq "Managed by node-enterprise-deploy-kit for ${APP_NAME:-}" "$config_path" 2>/dev/null; then
    REVERSE_PROXY_CONFIG_MANAGED_MARKER_FOUND="true"
  else
    add_warning "Reverse proxy config file exists, but it does not contain this kit's managed marker for the app."
  fi
}

first_line_from_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  IFS= read -r line < "$path" || return 1
  printf '%s\n' "$line"
}

next_build_id() {
  local root value
  root="${NEXTJS_RUNTIME_ROOT:-${APP_DIR:-}}"
  [[ -n "$root" ]] || return 1
  value="$(first_line_from_file "${root%/}/.next/BUILD_ID" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

deployment_manifest_path() {
  [[ -n "${APP_DIR:-}" ]] || return 1
  printf '%s/.node-enterprise-deploy.json\n' "${APP_DIR%/}"
}

deployment_manifest_value() {
  local key="$1" manifest_path
  manifest_path="$(deployment_manifest_path 2>/dev/null || true)"
  [[ -n "$manifest_path" && -f "$manifest_path" ]] || return 1
  awk -v key="$key" '
    $0 ~ "\"" key "\"" {
      line=$0
      sub("^[^\"]*\"" key "\"[^\"]*\"", "", line)
      sub("\"[[:space:]]*,?[[:space:]]*$", "", line)
      gsub("\\\\\"", "\"", line)
      gsub("\\\\\\\\", "\\", line)
      print line
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$manifest_path" 2>/dev/null
}

update_deployment_identity() {
  DEPLOYMENT_IDENTITY_APP_DIR_NAME="$(basename "${APP_DIR:-}" 2>/dev/null || echo "")"
  if [[ -f "$(deployment_manifest_path 2>/dev/null || echo "")" ]]; then
    DEPLOYMENT_IDENTITY_MANIFEST_EXISTS="true"
    DEPLOYMENT_IDENTITY_MANIFEST_SCHEMA="$(deployment_manifest_value schema 2>/dev/null || echo "")"
    DEPLOYMENT_IDENTITY_PACKAGE_NAME="$(deployment_manifest_value packageName 2>/dev/null || echo "")"
    DEPLOYMENT_IDENTITY_PACKAGE_SHA256="$(deployment_manifest_value packageSha256 2>/dev/null || echo "")"
    DEPLOYMENT_IDENTITY_PACKAGE_IMPORTED_AT_UTC="$(deployment_manifest_value generatedAtUtc 2>/dev/null || echo "")"
    DEPLOYMENT_IDENTITY_MANIFEST_NEXT_BUILD_ID="$(deployment_manifest_value nextBuildId 2>/dev/null || echo "")"
  fi
  DEPLOYMENT_IDENTITY_DEPLOYMENT_ID="${NEXT_DEPLOYMENT_ID:-${DEPLOYMENT_ID:-}}"
  if [[ -z "$DEPLOYMENT_IDENTITY_DEPLOYMENT_ID" ]]; then
    DEPLOYMENT_IDENTITY_DEPLOYMENT_ID="$(deployment_manifest_value deploymentId 2>/dev/null || echo "")"
  fi
  DEPLOYMENT_IDENTITY_NEXT_BUILD_ID="$(next_build_id 2>/dev/null || echo "")"
  if [[ -z "$DEPLOYMENT_IDENTITY_NEXT_BUILD_ID" ]]; then
    DEPLOYMENT_IDENTITY_NEXT_BUILD_ID="$DEPLOYMENT_IDENTITY_MANIFEST_NEXT_BUILD_ID"
  fi
  if [[ -n "$DEPLOYMENT_IDENTITY_DEPLOYMENT_ID" || -n "$DEPLOYMENT_IDENTITY_NEXT_BUILD_ID" || -n "$DEPLOYMENT_IDENTITY_PACKAGE_SHA256" ]]; then
    DEPLOYMENT_IDENTITY_STATUS="ok"
  else
    DEPLOYMENT_IDENTITY_STATUS="unknown"
  fi
}

json_escape() {
  local value
  value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

safe_ci_path_value() {
  printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._/-'
}

safe_ci_token_value() {
  printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-'
}

safe_ci_digits_value() {
  printf '%s' "${1:-}" | tr -cd '0-9'
}

safe_ci_hex_value() {
  printf '%s' "${1:-}" | tr -cd 'A-Fa-f0-9'
}

collector_file_sha256() {
  local script_path hash
  script_path="${BASH_SOURCE[0]:-$0}"
  hash=""
  if [[ -r "$script_path" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      hash="$(sha256sum "$script_path" 2>/dev/null | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      hash="$(shasum -a 256 "$script_path" 2>/dev/null | awk '{print $1}')"
    elif command -v sha256 >/dev/null 2>&1; then
      hash="$(sha256 -q "$script_path" 2>/dev/null || sha256 "$script_path" 2>/dev/null | awk '{print $NF}')"
    fi
  fi
  if printf '%s' "$hash" | grep -Eq '^[A-Fa-f0-9]{64}$'; then
    printf '%s' "$hash" | tr 'A-F' 'a-f'
  else
    printf ''
  fi
}

is_env_true() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

os_release_value() {
  local key="$1"
  [[ -r /etc/os-release ]] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value=$2
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' /etc/os-release 2>/dev/null
}

sw_vers_value() {
  local key="$1"
  command -v sw_vers >/dev/null 2>&1 || return 1
  sw_vers "$key" 2>/dev/null || return 1
}

detect_libc() {
  local output version
  if command -v getconf >/dev/null 2>&1; then
    output="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    version="$(printf '%s\n' "$output" | awk 'tolower($1) == "glibc" { print $2; exit }')"
    if [[ -n "$version" ]]; then
      printf 'glibc|%s\n' "$version"
      return 0
    fi
  fi

  if command -v ldd >/dev/null 2>&1; then
    output="$(ldd --version 2>&1 || true)"
    if printf '%s\n' "$output" | grep -qi 'musl'; then
      version="$(printf '%s\n' "$output" | awk '/Version/ { print $2; exit }')"
      printf 'musl|%s\n' "$version"
      return 0
    fi
    version="$(printf '%s\n' "$output" | awk 'tolower($0) ~ /glibc|gnu libc/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+([.][0-9]+)+$/) { print $i; exit } }')"
    if [[ -n "$version" ]]; then
      printf 'glibc|%s\n' "$version"
      return 0
    fi
  fi

  printf '|\n'
}

status_platform_family() {
  local kernel
  kernel="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$kernel" in
    linux) echo "linux" ;;
    darwin) echo "macos" ;;
    freebsd) echo "freebsd" ;;
    openbsd) echo "openbsd" ;;
    netbsd) echo "netbsd" ;;
    *) echo "unix" ;;
  esac
}

host_uptime_seconds() {
  local uptime_value boot_seconds now_seconds
  if [[ -r /proc/uptime ]]; then
    uptime_value="$(awk '{ print int($1) }' /proc/uptime 2>/dev/null || true)"
    if is_integer "$uptime_value"; then
      printf '%s\n' "$uptime_value"
      return 0
    fi
  fi
  if command -v sysctl >/dev/null 2>&1; then
    boot_seconds="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p' | head -n 1)"
    now_seconds="$(date +%s 2>/dev/null || true)"
    if is_integer "$boot_seconds" && is_integer "$now_seconds" && [[ "$now_seconds" -ge "$boot_seconds" ]]; then
      printf '%s\n' "$((now_seconds - boot_seconds))"
      return 0
    fi
  fi
  return 1
}

format_seconds() {
  local total="${1:-0}" days hours minutes
  days=$((total / 86400))
  hours=$(((total % 86400) / 3600))
  minutes=$(((total % 3600) / 60))
  printf '%sd %sh %sm\n' "$days" "$hours" "$minutes"
}

parse_etime_seconds() {
  local value="${1:-}" days="0" rest first second third
  value="$(printf '%s' "$value" | tr -d ' ')"
  [[ -n "$value" ]] || return 1
  if [[ "$value" == *-* ]]; then
    days="${value%%-*}"
    rest="${value#*-}"
  else
    rest="$value"
  fi
  IFS=':' read -r first second third <<EOF
$rest
EOF
  if [[ -n "${third:-}" ]]; then
    echo $((days * 86400 + first * 3600 + second * 60 + third))
  elif [[ -n "${second:-}" ]]; then
    echo $((days * 86400 + first * 60 + second))
  else
    return 1
  fi
}

process_elapsed_seconds() {
  local pid="$1" elapsed
  [[ -n "$pid" && "$pid" != "0" ]] || return 1
  elapsed="$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || true)"
  if is_integer "$elapsed"; then
    printf '%s\n' "$elapsed"
    return 0
  fi
  elapsed="$(ps -p "$pid" -o etime= 2>/dev/null || true)"
  parse_etime_seconds "$elapsed"
}

trim_config_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s\n' "$value"
}

normalize_existing_path_for_compare() {
  local value
  value="$(trim_config_value "${1:-}")"
  if [[ -d "$value" ]]; then
    (cd "$value" 2>/dev/null && pwd -P) || printf '%s\n' "${value%/}"
  else
    printf '%s\n' "${value%/}"
  fi
}

path_matches_config() {
  local actual expected
  actual="$(normalize_existing_path_for_compare "${1:-}")"
  expected="$(normalize_existing_path_for_compare "${2:-}")"
  [[ -n "$actual" && -n "$expected" && "$actual" == "$expected" ]]
}

expected_service_command() {
  printf '%s\n' "$(trim_config_value "${NODE_BIN:-}") $(trim_config_value "${START_SCRIPT:-}") $(trim_config_value "${NODE_ARGUMENTS:-}")" |
    sed -E 's/[[:space:]]+$//'
}

expected_script_arguments() {
  printf '%s\n' "$(trim_config_value "${START_SCRIPT:-}") $(trim_config_value "${NODE_ARGUMENTS:-}")" |
    sed -E 's/[[:space:]]+$//'
}

file_key_value() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '
    $1 == key {
      value=$0
      sub("^[^=]*=", "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      found=1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$file" 2>/dev/null || true
}

plist_key_string_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "<key>" key "</key>" {
      while (getline > 0) {
        if ($0 ~ /<string>/) {
          value=$0
          sub(/^.*<string>/, "", value)
          sub(/<\/string>.*$/, "", value)
          print value
          found=1
          exit
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file" 2>/dev/null || true
}

set_service_definition_result() {
  SERVICE_DEFINITION_CHECKED="true"
  SERVICE_DEFINITION_MANAGER="$SERVICE_MANAGER_NORMALIZED"
  SERVICE_DEFINITION_SOURCE="$1"
  SERVICE_DEFINITION_EXISTS="$2"
  SERVICE_DEFINITION_NODE_EXE_MATCHES_CONFIG="$3"
  SERVICE_DEFINITION_WORKING_DIRECTORY_MATCHES_CONFIG="$4"
  SERVICE_DEFINITION_ARGUMENTS_MATCH_CONFIG="$5"
  SERVICE_DEFINITION_RUNNER_SCRIPT_MATCHES_CONFIG="${6:-false}"
}

check_shell_assignment_service_definition() {
  local source="$1" file="$2" node_bin app_dir start_script node_arguments args_match
  if [[ ! -f "$file" ]]; then
    set_service_definition_result "$source" "false" "false" "false" "false" "false"
    return
  fi
  node_bin="$(file_key_value "$file" "NODE_BIN")"
  app_dir="$(file_key_value "$file" "APP_DIR")"
  start_script="$(file_key_value "$file" "START_SCRIPT")"
  node_arguments="$(file_key_value "$file" "NODE_ARGUMENTS")"
  args_match="false"
  if [[ "$(trim_config_value "$start_script")" == "$(trim_config_value "${START_SCRIPT:-}")" &&
        "$(trim_config_value "$node_arguments")" == "$(trim_config_value "${NODE_ARGUMENTS:-}")" ]]; then
    args_match="true"
  fi
  set_service_definition_result "$source" "true" \
    "$(if path_matches_config "$node_bin" "${NODE_BIN:-}"; then echo true; else echo false; fi)" \
    "$(if path_matches_config "$app_dir" "${APP_DIR:-}"; then echo true; else echo false; fi)" \
    "$args_match" \
    "false"
}

service_definition_summary() {
  local unit_file init_file plist_file runner_file exec_start working_directory node_match workdir_match args_match runner_match command command_args directory
  if is_true "$SKIP_SERVICE_MANAGER_CHECK"; then
    set_service_definition_result "skipped" "false" "false" "false" "false" "false"
    return
  fi

  case "$SERVICE_MANAGER_NORMALIZED" in
    systemd)
      unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
      if [[ ! -f "$unit_file" ]]; then
        set_service_definition_result "systemd-unit" "false" "false" "false" "false" "false"
        return
      fi
      exec_start="$(file_key_value "$unit_file" "ExecStart")"
      working_directory="$(file_key_value "$unit_file" "WorkingDirectory")"
      [[ "$(trim_config_value "$exec_start")" == "$(expected_service_command)" ]] && args_match="true" || args_match="false"
      case "$(trim_config_value "$exec_start")" in
        "$(trim_config_value "${NODE_BIN:-}")"|"$(trim_config_value "${NODE_BIN:-}") "*) node_match="true" ;;
        *) node_match="false" ;;
      esac
      if path_matches_config "$working_directory" "${APP_DIR:-}"; then workdir_match="true"; else workdir_match="false"; fi
      set_service_definition_result "systemd-unit" "true" "$node_match" "$workdir_match" "$args_match" "false"
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      check_shell_assignment_service_definition "systemv-init" "/etc/init.d/${SERVICE_NAME}"
      ;;
    openrc)
      init_file="/etc/init.d/${SERVICE_NAME}"
      if [[ ! -f "$init_file" ]]; then
        set_service_definition_result "openrc-init" "false" "false" "false" "false" "false"
        return
      fi
      command="$(file_key_value "$init_file" "command")"
      command_args="$(file_key_value "$init_file" "command_args")"
      directory="$(file_key_value "$init_file" "directory")"
      if path_matches_config "$command" "${NODE_BIN:-}"; then node_match="true"; else node_match="false"; fi
      if path_matches_config "$directory" "${APP_DIR:-}"; then workdir_match="true"; else workdir_match="false"; fi
      [[ "$(trim_config_value "$command_args")" == "$(expected_script_arguments)" ]] && args_match="true" || args_match="false"
      set_service_definition_result "openrc-init" "true" "$node_match" "$workdir_match" "$args_match" "false"
      ;;
    launchd)
      plist_file="/Library/LaunchDaemons/${SERVICE_NAME}.plist"
      runner_file="${RUNNER_SCRIPT:-/usr/local/sbin/${SERVICE_NAME}-runner.sh}"
      if [[ ! -f "$plist_file" || ! -f "$runner_file" ]]; then
        set_service_definition_result "launchd-plist" "false" "false" "false" "false" "false"
        return
      fi
      working_directory="$(plist_key_string_value "$plist_file" "WorkingDirectory")"
      runner_match="false"
      if path_matches_config "$(plist_key_string_value "$plist_file" "ProgramArguments")" "$runner_file"; then
        runner_match="true"
      fi
      if grep -Fq "exec \"${NODE_BIN:-}\" \"${START_SCRIPT:-}\"" "$runner_file" 2>/dev/null; then node_match="true"; else node_match="false"; fi
      if path_matches_config "$working_directory" "${APP_DIR:-}" && grep -Fq "cd \"${APP_DIR:-}\"" "$runner_file" 2>/dev/null; then workdir_match="true"; else workdir_match="false"; fi
      if grep -Fq "exec \"${NODE_BIN:-}\" \"${START_SCRIPT:-}\" ${NODE_ARGUMENTS:-}" "$runner_file" 2>/dev/null; then args_match="true"; else args_match="false"; fi
      set_service_definition_result "launchd-plist" "true" "$node_match" "$workdir_match" "$args_match" "$runner_match"
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if [[ -f "/usr/local/etc/rc.d/${SERVICE_NAME}" ]]; then
        check_shell_assignment_service_definition "bsdrc-init" "/usr/local/etc/rc.d/${SERVICE_NAME}"
      else
        check_shell_assignment_service_definition "bsdrc-init" "/etc/rc.d/${SERVICE_NAME}"
      fi
      ;;
    *)
      set_service_definition_result "unsupported" "false" "false" "false" "false" "false"
      ;;
  esac
}

service_main_pid() {
  case "$SERVICE_MANAGER_NORMALIZED" in
    systemd)
      systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      read_pid_file "/var/run/${SERVICE_NAME}/${SERVICE_NAME}.pid"
      ;;
    openrc)
      read_pid_file "/run/${SERVICE_NAME}/${SERVICE_NAME}.pid"
      ;;
    launchd)
      if command -v launchctl >/dev/null 2>&1; then
        launchctl print "system/${SERVICE_NAME}" 2>/dev/null |
          awk -F= '/pid[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; found=1; exit } END { exit found ? 0 : 1 }' ||
          true
      fi
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      read_pid_file "/var/run/${SERVICE_NAME}/${SERVICE_NAME}.pid"
      ;;
    *)
      echo ""
      ;;
  esac
}

read_pid_file() {
  local path="$1" pid
  [[ -f "$path" ]] || return 0
  pid="$(tr -d '[:space:]' < "$path" 2>/dev/null || true)"
  if is_integer "$pid" && [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
  fi
}

service_is_active() {
  case "$SERVICE_MANAGER_NORMALIZED" in
    systemd)
      systemctl is-active --quiet "$SERVICE_NAME"
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      if command -v service >/dev/null 2>&1; then service "$SERVICE_NAME" status >/dev/null 2>&1; else "/etc/init.d/${SERVICE_NAME}" status >/dev/null 2>&1; fi
      ;;
    openrc)
      rc-service "$SERVICE_NAME" status >/dev/null 2>&1
      ;;
    launchd)
      launchctl print "system/${SERVICE_NAME}" >/dev/null 2>&1
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      if command -v service >/dev/null 2>&1; then
        service "$SERVICE_NAME" status >/dev/null 2>&1
      elif command -v rcctl >/dev/null 2>&1; then
        rcctl check "$SERVICE_NAME" >/dev/null 2>&1
      elif [[ -x "/usr/local/etc/rc.d/${SERVICE_NAME}" ]]; then
        "/usr/local/etc/rc.d/${SERVICE_NAME}" status >/dev/null 2>&1
      else
        "/etc/rc.d/${SERVICE_NAME}" status >/dev/null 2>&1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

systemv_enabled_status() {
  local link
  if command -v chkconfig >/dev/null 2>&1; then
    if chkconfig --list "$SERVICE_NAME" 2>/dev/null | grep -Eq ':[[:space:]]*on|[0-6]:on'; then
      echo "enabled"
    else
      echo "disabled"
    fi
    return
  fi

  for link in /etc/rc*.d/S*"${SERVICE_NAME}"; do
    if [[ -e "$link" ]]; then
      echo "enabled"
      return
    fi
  done

  if [[ -x "/etc/init.d/${SERVICE_NAME}" ]]; then
    echo "unknown"
  else
    echo "disabled"
  fi
}

openrc_enabled_status() {
  if ! command -v rc-update >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  if rc-update show 2>/dev/null | awk -v service="$SERVICE_NAME" '$1 == service { found=1 } END { exit found ? 0 : 1 }'; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

launchd_enabled_status() {
  local plist_file="/Library/LaunchDaemons/${SERVICE_NAME}.plist"
  if [[ ! -f "$plist_file" ]]; then
    echo "disabled"
    return
  fi
  if command -v launchctl >/dev/null 2>&1 &&
      launchctl print-disabled system 2>/dev/null | grep -F "\"${SERVICE_NAME}\" => true" >/dev/null 2>&1; then
    echo "disabled"
  else
    echo "enabled"
  fi
}

rc_conf_service_enabled() {
  local file
  for file in /etc/rc.conf /etc/rc.conf.local "/etc/rc.conf.d/${SERVICE_NAME}" "/usr/local/etc/rc.conf.d/${SERVICE_NAME}"; do
    [[ -f "$file" ]] || continue
    if grep -F "${SERVICE_NAME}_enable" "$file" 2>/dev/null | grep -Eiq 'yes|true|on'; then
      echo "enabled"
      return
    fi
    if grep -F "${SERVICE_NAME}=YES" "$file" >/dev/null 2>&1; then
      echo "enabled"
      return
    fi
  done
  echo "disabled"
}

bsdrc_enabled_status() {
  local status=""
  if command -v rcctl >/dev/null 2>&1; then
    status="$(rcctl get "$SERVICE_NAME" status 2>/dev/null || true)"
    case "$status" in
      on|enabled) echo "enabled"; return ;;
      off|disabled) echo "disabled"; return ;;
    esac
  fi
  if command -v service >/dev/null 2>&1 && service -e >/dev/null 2>&1; then
    if service -e 2>/dev/null | grep -E "/${SERVICE_NAME}$" >/dev/null 2>&1; then
      echo "enabled"
    else
      echo "disabled"
    fi
    return
  fi
  rc_conf_service_enabled
}

service_enabled_status() {
  case "$SERVICE_MANAGER_NORMALIZED" in
    systemd)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo "unknown"
      else
        echo "unknown"
      fi
      ;;
    systemv|sysv|sysvinit|initd|init-d)
      systemv_enabled_status
      ;;
    openrc)
      openrc_enabled_status
      ;;
    launchd)
      launchd_enabled_status
      ;;
    bsdrc|bsd-rc|rcd|rc.d)
      bsdrc_enabled_status
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

service_enabled_is_good() {
  case "${1:-}" in
    enabled|static|generated|linked|linked-runtime|indirect|enabled-runtime) return 0 ;;
    *) return 1 ;;
  esac
}

port_owner_pids() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null |
      awk -v port=":$port" '$0 ~ port { print }' |
      sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
      sort -u
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u
  else
    return 1
  fi
}

port_has_listener() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v port=":$port" '$0 ~ port { found=1 } END { exit found ? 0 : 1 }'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | awk -v port=".$port" '$0 ~ port && $0 ~ /LISTEN/ { found=1 } END { exit found ? 0 : 1 }'
  else
    return 2
  fi
}

read_health_state_value() {
  local key="$1"
  [[ -f "$HEALTHCHECK_STATE_FILE" ]] || return 1
  awk -F= -v key="$key" '$1 == key { print $2; found=1 } END { exit found ? 0 : 1 }' "$HEALTHCHECK_STATE_FILE" 2>/dev/null
}

cron_daemon_is_active() {
  local service_name
  for service_name in cron crond; do
    if command -v rc-service >/dev/null 2>&1 && rc-service "$service_name" status >/dev/null 2>&1; then
      printf '%s\n' "$service_name:active"
      return 0
    fi
    if command -v service >/dev/null 2>&1 && service "$service_name" status >/dev/null 2>&1; then
      printf '%s\n' "$service_name:active"
      return 0
    fi
    if command -v rcctl >/dev/null 2>&1 && rcctl check "$service_name" >/dev/null 2>&1; then
      printf '%s\n' "$service_name:active"
      return 0
    fi
  done
  if command -v pgrep >/dev/null 2>&1 && { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }; then
    printf '%s\n' "process:active"
    return 0
  fi
  if ps -A -o comm= 2>/dev/null | awk '$1 == "cron" || $1 == "crond" { found=1 } END { exit found ? 0 : 1 }'; then
    printf '%s\n' "process:active"
    return 0
  fi
  return 1
}

health_scheduler_summary() {
  local timer_unit active_status enabled_status label plist_file marker_start cron_status
  echo "HealthSchedulerType=$HEALTH_MONITOR_SCHEDULE_TYPE"
  case "$HEALTH_MONITOR_SCHEDULE_TYPE" in
    systemd-timer)
      HEALTH_MONITOR_SCHEDULER_CHECKED="true"
      timer_unit="${APP_NAME}-healthcheck.timer"
      if ! command -v systemctl >/dev/null 2>&1; then
        add_warning "systemctl was not found, so the healthcheck timer could not be checked."
        echo "HealthSchedulerChecked=true"
        echo "HealthTimerExists=false"
        return
      fi

      echo "HealthSchedulerChecked=true"
      if systemctl list-unit-files "$timer_unit" --no-legend --no-pager 2>/dev/null | awk '{ found=1 } END { exit found ? 0 : 1 }'; then
        HEALTH_MONITOR_SCHEDULER_EXISTS="true"
      elif systemctl status "$timer_unit" --no-pager >/dev/null 2>&1; then
        HEALTH_MONITOR_SCHEDULER_EXISTS="true"
      fi
      echo "HealthTimerExists=$HEALTH_MONITOR_SCHEDULER_EXISTS"

      active_status="$(systemctl is-active "$timer_unit" 2>/dev/null || echo "unknown")"
      enabled_status="$(systemctl is-enabled "$timer_unit" 2>/dev/null || echo "unknown")"
      HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS="$active_status"
      HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS="$enabled_status"
      if [[ "$active_status" == "active" ]]; then
        HEALTH_MONITOR_SCHEDULER_ACTIVE="true"
      fi
      if service_enabled_is_good "$enabled_status"; then
        HEALTH_MONITOR_SCHEDULER_ENABLED="true"
      fi

      echo "HealthTimerActiveStatus=$active_status"
      echo "HealthTimerEnabledStatus=$enabled_status"
      if [[ "$HEALTH_MONITOR_SCHEDULER_EXISTS" != "true" ]]; then
        add_warning "Healthcheck systemd timer '$timer_unit' was not found."
      elif [[ "$HEALTH_MONITOR_SCHEDULER_ACTIVE" != "true" ]]; then
        add_warning "Healthcheck systemd timer '$timer_unit' is not active (status: $active_status)."
      elif [[ "$HEALTH_MONITOR_SCHEDULER_ENABLED" != "true" ]]; then
        add_warning "Healthcheck systemd timer '$timer_unit' is not enabled for boot (status: $enabled_status)."
      fi
      ;;
    launchd-timer)
      HEALTH_MONITOR_SCHEDULER_CHECKED="true"
      label="${APP_NAME}-healthcheck"
      plist_file="/Library/LaunchDaemons/${label}.plist"
      if [[ -f "$plist_file" ]]; then
        HEALTH_MONITOR_SCHEDULER_EXISTS="true"
      fi
      echo "HealthSchedulerChecked=true"
      echo "HealthLaunchdPlistExists=$HEALTH_MONITOR_SCHEDULER_EXISTS"
      if command -v launchctl >/dev/null 2>&1 && launchctl print "system/${label}" >/dev/null 2>&1; then
        HEALTH_MONITOR_SCHEDULER_ACTIVE="true"
        HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS="active"
      else
        HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS="inactive"
      fi
      if command -v launchctl >/dev/null 2>&1 &&
          launchctl print-disabled system 2>/dev/null | grep -F "\"${label}\" => true" >/dev/null 2>&1; then
        HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS="disabled"
      elif [[ "$HEALTH_MONITOR_SCHEDULER_EXISTS" == "true" ]]; then
        HEALTH_MONITOR_SCHEDULER_ENABLED="true"
        HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS="enabled"
      fi
      echo "HealthLaunchdActiveStatus=$HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS"
      echo "HealthLaunchdEnabledStatus=$HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS"
      if [[ "$HEALTH_MONITOR_SCHEDULER_EXISTS" != "true" ]]; then
        add_warning "Healthcheck launchd plist '$label' was not found."
      elif [[ "$HEALTH_MONITOR_SCHEDULER_ACTIVE" != "true" ]]; then
        add_warning "Healthcheck launchd job '$label' is not active."
      elif [[ "$HEALTH_MONITOR_SCHEDULER_ENABLED" != "true" ]]; then
        add_warning "Healthcheck launchd job '$label' is not enabled."
      fi
      ;;
    cron)
      HEALTH_MONITOR_SCHEDULER_CHECKED="true"
      marker_start="# node-enterprise-deploy-kit:${APP_NAME}:healthcheck:start"
      echo "HealthSchedulerChecked=true"
      if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -Fx "$marker_start" >/dev/null 2>&1; then
        HEALTH_MONITOR_SCHEDULER_EXISTS="true"
      fi
      echo "HealthCronEntryExists=$HEALTH_MONITOR_SCHEDULER_EXISTS"
      cron_status="$(cron_daemon_is_active 2>/dev/null || echo "inactive")"
      HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS="$cron_status"
      if [[ "$cron_status" != "inactive" ]]; then
        HEALTH_MONITOR_SCHEDULER_ACTIVE="true"
      fi
      if [[ "$HEALTH_MONITOR_SCHEDULER_EXISTS" == "true" ]]; then
        HEALTH_MONITOR_SCHEDULER_ENABLED="true"
        HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS="persistent-entry"
      fi
      echo "HealthCronActiveStatus=$HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS"
      echo "HealthCronEnabledStatus=$HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS"
      if [[ "$HEALTH_MONITOR_SCHEDULER_EXISTS" != "true" ]]; then
        add_warning "Managed root crontab healthcheck entry was not found."
      elif [[ "$HEALTH_MONITOR_SCHEDULER_ACTIVE" != "true" ]]; then
        add_warning "Cron daemon was not detected as active for the managed healthcheck entry."
      fi
      ;;
    *)
      return
      ;;
  esac

  HEALTH_MONITOR_SCHEDULER_CHECKED="true"
  if [[ "$HEALTH_MONITOR_SCHEDULER_EXISTS" == "true" &&
        "$HEALTH_MONITOR_SCHEDULER_ACTIVE" == "true" &&
        "$HEALTH_MONITOR_SCHEDULER_ENABLED" == "true" ]]; then
    HEALTH_MONITOR_SCHEDULED="true"
  fi
}

health_state_summary() {
  local failures last_success last_check now stale_after age
  if [[ ! -f "$HEALTHCHECK_STATE_FILE" ]]; then
    HEALTH_MONITOR_STATE_EXISTS="false"
    add_warning "Healthcheck state file was not found yet."
    echo "HealthStateFileExists=false"
    return
  fi

  if [[ "$HEALTH_MONITOR_SCHEDULE_TYPE" == "state-log" ]]; then
    HEALTH_MONITOR_SCHEDULED="true"
  fi
  HEALTH_MONITOR_STATE_EXISTS="true"
  failures="$(read_health_state_value CONSECUTIVE_FAILURES || echo 0)"
  last_success="$(read_health_state_value LAST_SUCCESS_EPOCH || echo 0)"
  last_check="$(read_health_state_value LAST_CHECK_EPOCH || echo 0)"
  HEALTH_MONITOR_CONSECUTIVE_FAILURES="$failures"
  echo "HealthStateFileExists=true"
  echo "ConsecutiveFailures=$failures"
  echo "LastCheckEpoch=$last_check"
  echo "LastSuccessEpoch=$last_success"

  if is_integer "$failures" && [[ "$failures" -ge "$HEALTHCHECK_FAILURE_THRESHOLD" ]]; then
    add_critical "Healthcheck state has $failures consecutive failures, meeting or exceeding threshold $HEALTHCHECK_FAILURE_THRESHOLD."
  elif is_integer "$failures" && [[ "$failures" -gt 0 ]]; then
    add_warning "Healthcheck state has $failures consecutive failures."
  fi

  now="$(date +%s)"
  stale_after=$((HEALTHCHECK_INTERVAL * 3))
  if [[ "$stale_after" -lt 300 ]]; then stale_after=300; fi
  if is_integer "$last_success" && [[ "$last_success" -gt 0 ]]; then
    age=$((now - last_success))
    if [[ "$age" -lt 0 ]]; then age=0; fi
    HEALTH_MONITOR_LAST_SUCCESS_AGE_SECONDS="$age"
    echo "LastSuccessAgeSeconds=$age"
    if [[ "$age" -gt "$stale_after" ]]; then
      add_warning "Last successful health check is older than $stale_after seconds."
    else
      HEALTH_MONITOR_LAST_SUCCESS_FRESH="true"
    fi
  else
    add_warning "Healthcheck state has no recorded successful check yet."
  fi
}

health_log_summary() {
  local path="${LOG_DIR:-}/healthcheck.log"
  local ok_count failure_count restart_count
  if [[ ! -f "$path" ]]; then
    HEALTH_MONITOR_LOG_EXISTS="false"
    add_warning "Healthcheck log was not found yet."
    echo "HealthLogExists=false"
    return
  fi
  HEALTH_MONITOR_LOG_EXISTS="true"
  ok_count="$(tail -n 2000 "$path" 2>/dev/null | grep -c ' OK ' || true)"
  failure_count="$(tail -n 2000 "$path" 2>/dev/null | grep -Ec ' FAILED|FAILED_THRESHOLD|HTTP_FAILED|BAD_STATUS|SERVICE_NOT_RUNNING' || true)"
  restart_count="$(tail -n 2000 "$path" 2>/dev/null | grep -Ec 'RESTARTING_SERVICE|SERVICE_NOT_RUNNING' || true)"
  HEALTH_MONITOR_LOG_FAILURE_COUNT="$failure_count"
  HEALTH_MONITOR_LOG_RESTART_COUNT="$restart_count"
  echo "HealthLogExists=true"
  echo "HealthLogPath=$path"
  echo "HealthLogOkCount=$ok_count"
  echo "HealthLogFailureCount=$failure_count"
  echo "HealthLogRestartCount=$restart_count"
}

write_json_output() {
  local output="$1"
  local output_dir
  local generated_at
  local safe_health_url
  local first
  local finding
  local severity
  local message
  local ci_is_ci
  local ci_provider

  output_dir="$(dirname "$output")"
  if [[ "$output_dir" != "." ]]; then
    mkdir -p "$output_dir"
  fi
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  safe_health_url="$(safe_url "${HEALTH_URL:-}")"
  ci_is_ci="false"
  ci_provider=""
  if is_env_true "${GITHUB_ACTIONS:-}"; then
    ci_is_ci="true"
    ci_provider="github-actions"
  elif is_env_true "${CI:-}"; then
    ci_is_ci="true"
    ci_provider="ci"
  fi

  {
    printf '{\n'
    printf '  "evidenceSchemaVersion": 1,\n'
    printf '  "evidenceCollection": {\n'
    printf '    "source": "node-enterprise-deploy-kit/status-node-app.sh",\n'
    printf '    "collector": "scripts/linux/status-node-app.sh",\n'
    printf '    "collectorVersion": 1,\n'
    printf '    "collectorSha256": "%s",\n' "$(json_escape "$(collector_file_sha256)")"
    printf '    "liveHost": true,\n'
    printf '    "synthetic": false,\n'
    printf '    "mock": false,\n'
    printf '    "sample": false,\n'
    printf '    "ci": {\n'
    printf '      "isCi": %s,\n' "$ci_is_ci"
    printf '      "provider": "%s",\n' "$(json_escape "$ci_provider")"
    printf '      "workflowName": "%s",\n' "$(json_escape "$(safe_ci_path_value "${GITHUB_WORKFLOW:-}")")"
    printf '      "runId": "%s",\n' "$(json_escape "$(safe_ci_digits_value "${GITHUB_RUN_ID:-}")")"
    printf '      "runAttempt": "%s",\n' "$(json_escape "$(safe_ci_digits_value "${GITHUB_RUN_ATTEMPT:-}")")"
    printf '      "eventName": "%s",\n' "$(json_escape "$(safe_ci_token_value "${GITHUB_EVENT_NAME:-}")")"
    printf '      "refName": "%s",\n' "$(json_escape "$(safe_ci_path_value "${GITHUB_REF_NAME:-}")")"
    printf '      "sha": "%s"\n' "$(json_escape "$(safe_ci_hex_value "${GITHUB_SHA:-}")")"
    printf '    }\n'
    printf '  },\n'
    printf '  "supportTargetId": "%s",\n' "$(json_escape "$SUPPORT_TARGET_ID")"
    printf '  "generatedAtUtc": "%s",\n' "$(json_escape "$generated_at")"
    printf '  "appName": "%s",\n' "$(json_escape "${APP_NAME:-}")"
    printf '  "serviceName": "%s",\n' "$(json_escape "$SERVICE_NAME")"
    printf '  "serviceManager": "%s",\n' "$(json_escape "$SERVICE_MANAGER_NORMALIZED")"
    printf '  "serviceActiveStatus": "%s",\n' "$(json_escape "$SERVICE_ACTIVE_STATUS")"
    printf '  "serviceEnabledStatus": "%s",\n' "$(json_escape "$SERVICE_ENABLED_STATUS")"
    printf '  "serviceDefinition": {\n'
    printf '    "checked": %s,\n' "$SERVICE_DEFINITION_CHECKED"
    printf '    "manager": "%s",\n' "$(json_escape "$SERVICE_DEFINITION_MANAGER")"
    printf '    "definitionSource": "%s",\n' "$(json_escape "$SERVICE_DEFINITION_SOURCE")"
    printf '    "definitionExists": %s,\n' "$SERVICE_DEFINITION_EXISTS"
    printf '    "nodeExeMatchesConfig": %s,\n' "$SERVICE_DEFINITION_NODE_EXE_MATCHES_CONFIG"
    printf '    "workingDirectoryMatchesConfig": %s,\n' "$SERVICE_DEFINITION_WORKING_DIRECTORY_MATCHES_CONFIG"
    printf '    "argumentsMatchConfig": %s,\n' "$SERVICE_DEFINITION_ARGUMENTS_MATCH_CONFIG"
    printf '    "runnerScriptMatchesConfig": %s\n' "$SERVICE_DEFINITION_RUNNER_SCRIPT_MATCHES_CONFIG"
    printf '  },\n'
    printf '  "appRuntime": "%s",\n' "$(json_escape "$APP_RUNTIME_NORMALIZED")"
    printf '  "configFileName": "%s",\n' "$(json_escape "$(safe_path_name "$CONFIG_FILE")")"
    printf '  "appPort": "%s",\n' "$(json_escape "${APP_PORT:-}")"
    printf '  "healthUrl": "%s",\n' "$(json_escape "$safe_health_url")"
    printf '  "port": {\n'
    printf '    "checked": %s,\n' "$PORT_CHECKED"
    printf '    "port": "%s",\n' "$(json_escape "${APP_PORT:-}")"
    printf '    "listening": %s,\n' "$PORT_LISTENING"
    printf '    "ownerReadable": %s,\n' "$PORT_OWNER_READABLE"
    printf '    "ownerProcessCount": %s,\n' "$PORT_OWNER_PROCESS_COUNT"
    printf '    "servicePidKnown": %s,\n' "$PORT_SERVICE_PID_KNOWN"
    printf '    "ownedByService": %s\n' "$PORT_OWNED_BY_SERVICE"
    printf '  },\n'
    printf '  "health": {\n'
    printf '    "checked": %s,\n' "$HEALTH_CHECKED"
    printf '    "url": "%s",\n' "$(json_escape "$(safe_url "$HEALTH_PROBE_URL")")"
    printf '    "status": "%s",\n' "$(json_escape "$HEALTH_STATUS")"
    if is_integer "$HEALTH_STATUS_CODE"; then
      printf '    "statusCode": %s,\n' "$((10#$HEALTH_STATUS_CODE))"
    else
      printf '    "statusCode": null,\n'
    fi
    printf '    "responseSeconds": "%s",\n' "$(json_escape "$HEALTH_RESPONSE_SECONDS")"
    printf '    "timeoutSeconds": "%s"\n' "$(json_escape "$HEALTH_TIMEOUT_SECONDS")"
    printf '  },\n'
    printf '  "uptime": {\n'
    if is_integer "$HOST_UPTIME_SECONDS"; then
      printf '    "hostUptimeSeconds": %s,\n' "$((10#$HOST_UPTIME_SECONDS))"
    else
      printf '    "hostUptimeSeconds": null,\n'
    fi
    if is_integer "$SERVICE_UPTIME_SECONDS"; then
      printf '    "serviceUptimeSeconds": %s,\n' "$((10#$SERVICE_UPTIME_SECONDS))"
    else
      printf '    "serviceUptimeSeconds": null,\n'
    fi
    printf '    "minimumUptimeHours": "%s",\n' "$(json_escape "$MINIMUM_UPTIME_HOURS")"
    if [[ "$UPTIME_MINIMUM_SATISFIED" == "true" || "$UPTIME_MINIMUM_SATISFIED" == "false" ]]; then
      printf '    "minimumSatisfied": %s,\n' "$UPTIME_MINIMUM_SATISFIED"
    else
      printf '    "minimumSatisfied": null,\n'
    fi
    printf '    "serviceStartKnown": %s\n' "$SERVICE_START_KNOWN"
    printf '  },\n'
    printf '  "healthMonitor": {\n'
    printf '    "status": "%s",\n' "$(json_escape "$HEALTH_MONITOR_STATUS")"
    printf '    "scheduled": %s,\n' "$HEALTH_MONITOR_SCHEDULED"
    printf '    "scheduleType": "%s",\n' "$(json_escape "$HEALTH_MONITOR_SCHEDULE_TYPE")"
    printf '    "stateExists": %s,\n' "$HEALTH_MONITOR_STATE_EXISTS"
    if is_integer "$HEALTH_MONITOR_CONSECUTIVE_FAILURES"; then
      printf '    "consecutiveFailures": %s,\n' "$((10#$HEALTH_MONITOR_CONSECUTIVE_FAILURES))"
    else
      printf '    "consecutiveFailures": null,\n'
    fi
    if is_integer "$HEALTH_MONITOR_LAST_SUCCESS_AGE_SECONDS"; then
      printf '    "lastSuccessAgeSeconds": %s,\n' "$((10#$HEALTH_MONITOR_LAST_SUCCESS_AGE_SECONDS))"
    else
      printf '    "lastSuccessAgeSeconds": null,\n'
    fi
    printf '    "lastSuccessFresh": %s,\n' "$HEALTH_MONITOR_LAST_SUCCESS_FRESH"
    printf '    "logExists": %s,\n' "$HEALTH_MONITOR_LOG_EXISTS"
    if is_integer "$HEALTH_MONITOR_LOG_FAILURE_COUNT"; then
      printf '    "logFailureCount": %s,\n' "$((10#$HEALTH_MONITOR_LOG_FAILURE_COUNT))"
    else
      printf '    "logFailureCount": null,\n'
    fi
    if is_integer "$HEALTH_MONITOR_LOG_RESTART_COUNT"; then
      printf '    "logRestartCount": %s,\n' "$((10#$HEALTH_MONITOR_LOG_RESTART_COUNT))"
    else
      printf '    "logRestartCount": null,\n'
    fi
    printf '    "schedulerChecked": %s,\n' "$HEALTH_MONITOR_SCHEDULER_CHECKED"
    printf '    "schedulerExists": %s,\n' "$HEALTH_MONITOR_SCHEDULER_EXISTS"
    printf '    "schedulerActive": %s,\n' "$HEALTH_MONITOR_SCHEDULER_ACTIVE"
    printf '    "schedulerEnabled": %s,\n' "$HEALTH_MONITOR_SCHEDULER_ENABLED"
    printf '    "schedulerActiveStatus": "%s",\n' "$(json_escape "$HEALTH_MONITOR_SCHEDULER_ACTIVE_STATUS")"
    printf '    "schedulerEnabledStatus": "%s"\n' "$(json_escape "$HEALTH_MONITOR_SCHEDULER_ENABLED_STATUS")"
    printf '  },\n'
    printf '  "nextJsRuntime": {\n'
    printf '    "applicable": %s,\n' "$NEXTJS_LAYOUT_APPLICABLE"
    printf '    "status": "%s",\n' "$(json_escape "$NEXTJS_LAYOUT_STATUS")"
    printf '    "appFramework": "%s",\n' "$(json_escape "$APP_FRAMEWORK_NORMALIZED")"
    printf '    "mode": "%s",\n' "$(json_escape "$NEXTJS_DEPLOYMENT_MODE_NORMALIZED")"
    printf '    "nodeVersion": "%s",\n' "$(json_escape "$NODE_RUNTIME_VERSION")"
    printf '    "minimumNodeVersion": "%s",\n' "$(json_escape "$NEXTJS_MINIMUM_NODE_VERSION_EFFECTIVE")"
    if [[ "$NEXTJS_NODE_VERSION_SATISFIED" == "true" || "$NEXTJS_NODE_VERSION_SATISFIED" == "false" ]]; then
      printf '    "nodeVersionSatisfied": %s,\n' "$NEXTJS_NODE_VERSION_SATISFIED"
    else
      printf '    "nodeVersionSatisfied": null,\n'
    fi
    printf '    "nextVersion": "%s",\n' "$(json_escape "$NEXT_PACKAGE_VERSION")"
    if [[ "$NEXT_START_SCRIPT_IS_EXPECTED_CLI" == "true" || "$NEXT_START_SCRIPT_IS_EXPECTED_CLI" == "false" ]]; then
      printf '    "nextStartScriptIsExpectedCli": %s,\n' "$NEXT_START_SCRIPT_IS_EXPECTED_CLI"
    else
      printf '    "nextStartScriptIsExpectedCli": null,\n'
    fi
    printf '    "runtimeRootName": "%s"\n' "$(json_escape "$(safe_path_name "${NEXTJS_RUNTIME_ROOT:-${APP_DIR:-}}")")"
    printf '  },\n'
    printf '  "reverseProxy": {\n'
    printf '    "applicable": %s,\n' "$REVERSE_PROXY_APPLICABLE"
    printf '    "mode": "%s",\n' "$(json_escape "$REVERSE_PROXY_NORMALIZED")"
    printf '    "status": "%s",\n' "$(json_escape "$REVERSE_PROXY_STATUS")"
    printf '    "probeUrl": "%s",\n' "$(json_escape "$(safe_url "$REVERSE_PROXY_PROBE_URL")")"
    if is_integer "$REVERSE_PROXY_STATUS_CODE"; then
      printf '    "statusCode": %s,\n' "$((10#$REVERSE_PROXY_STATUS_CODE))"
    else
      printf '    "statusCode": null,\n'
    fi
    printf '    "responseSeconds": "%s",\n' "$(json_escape "$REVERSE_PROXY_RESPONSE_SECONDS")"
    printf '    "config": {\n'
    printf '      "applicable": %s,\n' "$REVERSE_PROXY_CONFIG_APPLICABLE"
    printf '      "pathName": "%s",\n' "$(json_escape "$REVERSE_PROXY_CONFIG_PATH_NAME")"
    printf '      "directoryName": "%s",\n' "$(json_escape "$REVERSE_PROXY_CONFIG_DIR_NAME")"
    printf '      "exists": %s,\n' "$REVERSE_PROXY_CONFIG_EXISTS"
    printf '      "managedMarkerFound": %s,\n' "$REVERSE_PROXY_CONFIG_MANAGED_MARKER_FOUND"
    printf '      "expectedPort": "%s"\n' "$(json_escape "$REVERSE_PROXY_CONFIG_EXPECTED_PORT")"
    printf '    }\n'
    printf '  },\n'
    printf '  "deploymentIdentity": {\n'
    printf '    "status": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_STATUS")"
    printf '    "appDirectoryName": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_APP_DIR_NAME")"
    printf '    "deploymentId": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_DEPLOYMENT_ID")"
    printf '    "nextBuildId": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_NEXT_BUILD_ID")"
    printf '    "manifestExists": %s,\n' "$DEPLOYMENT_IDENTITY_MANIFEST_EXISTS"
    printf '    "manifestSchema": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_MANIFEST_SCHEMA")"
    printf '    "packageName": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_PACKAGE_NAME")"
    printf '    "packageSha256": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_PACKAGE_SHA256")"
    printf '    "packageImportedAtUtc": "%s",\n' "$(json_escape "$DEPLOYMENT_IDENTITY_PACKAGE_IMPORTED_AT_UTC")"
    printf '    "manifestNextBuildId": "%s"\n' "$(json_escape "$DEPLOYMENT_IDENTITY_MANIFEST_NEXT_BUILD_ID")"
    printf '  },\n'
    printf '  "platform": {\n'
    printf '    "family": "%s",\n' "$(json_escape "$PLATFORM_FAMILY")"
    printf '    "supportTargetId": "%s",\n' "$(json_escape "$SUPPORT_TARGET_ID")"
    printf '    "kernelName": "%s",\n' "$(json_escape "$KERNEL_NAME")"
    printf '    "kernelRelease": "%s",\n' "$(json_escape "$KERNEL_RELEASE")"
    printf '    "machine": "%s",\n' "$(json_escape "$KERNEL_MACHINE")"
    printf '    "osId": "%s",\n' "$(json_escape "$OS_RELEASE_ID")"
    printf '    "osIdLike": "%s",\n' "$(json_escape "$OS_RELEASE_ID_LIKE")"
    printf '    "osVersionId": "%s",\n' "$(json_escape "$OS_RELEASE_VERSION_ID")"
    printf '    "osPrettyName": "%s",\n' "$(json_escape "$OS_RELEASE_PRETTY_NAME")"
    printf '    "libcName": "%s",\n' "$(json_escape "$LIBC_NAME")"
    printf '    "libcVersion": "%s"\n' "$(json_escape "$LIBC_VERSION")"
    printf '  },\n'
    printf '  "minimumUptimeHours": "%s",\n' "$(json_escape "$MINIMUM_UPTIME_HOURS")"
    printf '  "healthTimeoutSeconds": "%s",\n' "$(json_escape "$HEALTH_TIMEOUT_SECONDS")"
    printf '  "verdict": "%s",\n' "$verdict"
    printf '  "critical": %s,\n' "$critical_count"
    printf '  "warnings": %s,\n' "$warning_count"
    printf '  "findings": [\n'
    first="true"
    for finding in "${findings[@]}"; do
      severity="${finding%%|*}"
      message="${finding#*|}"
      if [[ "$first" == "true" ]]; then
        first="false"
      else
        printf ',\n'
      fi
      printf '    { "severity": "%s", "message": "%s" }' "$(json_escape "$severity")" "$(json_escape "$(safe_evidence_text "$message")")"
    done
    printf '\n'
    printf '  ]\n'
    printf '}\n'
  } > "$output"

  echo "JSON status evidence written to: $output"
}

run_nextjs_layout_check() {
  local output exit_code runtime_root minimum_node_version node_version_satisfied next_start_script_is_expected_cli
  NODE_RUNTIME_VERSION="$(node_runtime_version)"
  NEXT_PACKAGE_VERSION="$(next_package_version)"
  case "$APP_FRAMEWORK_NORMALIZED" in
    next|nextjs|next-js)
      NEXTJS_LAYOUT_APPLICABLE="true"
      NEXTJS_LAYOUT_STATUS="checking"
      ;;
    *)
      NEXTJS_LAYOUT_APPLICABLE="false"
      NEXTJS_LAYOUT_STATUS="not-applicable"
      echo "Next.js runtime layout check not applicable."
      return
      ;;
  esac

  set +e
  output="$(bash "$SCRIPT_DIR/test-nextjs-runtime-layout.sh" "$CONFIG_FILE" 2>&1)"
  exit_code=$?
  set -e
  printf '%s\n' "$output"
  runtime_root="$(printf '%s\n' "$output" | awk -v key="RuntimeRoot" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }')"
  minimum_node_version="$(printf '%s\n' "$output" | awk -v key="MinimumNodeVersion" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }')"
  node_version_satisfied="$(printf '%s\n' "$output" | awk -v key="NodeVersionSatisfied" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }')"
  next_start_script_is_expected_cli="$(printf '%s\n' "$output" | awk -v key="NextStartScriptIsExpectedCli" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }')"
  if [[ -n "$runtime_root" ]]; then
    NEXTJS_RUNTIME_ROOT="$runtime_root"
  else
    NEXTJS_RUNTIME_ROOT="${APP_DIR:-}"
  fi
  if [[ -n "$minimum_node_version" ]]; then
    NEXTJS_MINIMUM_NODE_VERSION_EFFECTIVE="$minimum_node_version"
  fi
  case "$node_version_satisfied" in
    true|false) NEXTJS_NODE_VERSION_SATISFIED="$node_version_satisfied" ;;
  esac
  case "$next_start_script_is_expected_cli" in
    true|false) NEXT_START_SCRIPT_IS_EXPECTED_CLI="$next_start_script_is_expected_cli" ;;
  esac
  if [[ "$exit_code" -ne 0 ]]; then
    NEXTJS_LAYOUT_STATUS="failed"
    add_critical "Next.js runtime layout check failed."
  else
    NEXTJS_LAYOUT_STATUS="ok"
  fi
}

KERNEL_NAME="$(uname -s 2>/dev/null || echo unknown)"
KERNEL_RELEASE="$(uname -r 2>/dev/null || echo unknown)"
KERNEL_MACHINE="$(uname -m 2>/dev/null || echo unknown)"
PLATFORM_FAMILY="$(status_platform_family "$KERNEL_NAME")"
OS_RELEASE_ID="$(os_release_value ID || echo "")"
OS_RELEASE_ID_LIKE="$(os_release_value ID_LIKE || echo "")"
OS_RELEASE_VERSION_ID="$(os_release_value VERSION_ID || echo "")"
OS_RELEASE_PRETTY_NAME="$(os_release_value PRETTY_NAME || echo "")"
if [[ "$(printf '%s' "$KERNEL_NAME" | tr '[:upper:]' '[:lower:]')" == "darwin" ]]; then
  if [[ -z "$OS_RELEASE_VERSION_ID" ]]; then
    OS_RELEASE_VERSION_ID="$(sw_vers_value -productVersion || echo "")"
  fi
  if [[ -z "$OS_RELEASE_PRETTY_NAME" ]]; then
    OS_RELEASE_PRETTY_NAME="$(sw_vers_value -productName || echo "Apple macOS")"
    if [[ -n "$OS_RELEASE_VERSION_ID" ]]; then
      OS_RELEASE_PRETTY_NAME="$OS_RELEASE_PRETTY_NAME $OS_RELEASE_VERSION_ID"
    fi
  fi
fi
LIBC_INFO="$(detect_libc)"
LIBC_NAME="${LIBC_INFO%%|*}"
LIBC_VERSION="${LIBC_INFO#*|}"
SUPPORT_TARGET_ID="$(support_target_id)"

echo "Status for: ${APP_NAME:-unknown}"
echo "Config: $CONFIG_FILE"
echo "GeneratedAtUtc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "SupportTargetId=$SUPPORT_TARGET_ID"
echo "ServiceName=$SERVICE_NAME"
echo "ServiceManager=$SERVICE_MANAGER_NORMALIZED"
echo "AppRuntime=$APP_RUNTIME_NORMALIZED"
echo "AppPort=${APP_PORT:-}"
echo "HealthUrl=$(safe_url "${HEALTH_URL:-}")"

echo
echo "Host"
uname -srm || true
if HOST_UPTIME_SECONDS="$(host_uptime_seconds 2>/dev/null)"; then
  echo "HostUptime=$(format_seconds "$HOST_UPTIME_SECONDS")"
fi
if [[ -r /etc/os-release ]]; then
  grep -E '^(ID|ID_LIKE|VERSION_ID|PRETTY_NAME)=' /etc/os-release || true
fi

service_pid=""
echo
echo "Service"
if is_true "$SKIP_SERVICE_MANAGER_CHECK"; then
  SERVICE_ACTIVE_STATUS="skipped"
  SERVICE_ENABLED_STATUS="skipped"
  set_service_definition_result "skipped" "false" "false" "false" "false" "false"
  echo "Service manager check skipped."
else
  if service_is_active; then
    SERVICE_ACTIVE_STATUS="active"
    echo "ServiceActive=true"
  else
    SERVICE_ACTIVE_STATUS="inactive"
    add_critical "Service '$SERVICE_NAME' is not active according to $SERVICE_MANAGER_NORMALIZED."
    echo "ServiceActive=false"
  fi
  SERVICE_ENABLED_STATUS="$(service_enabled_status)"
  echo "ServiceEnabled=$SERVICE_ENABLED_STATUS"
  if service_enabled_is_good "$SERVICE_ENABLED_STATUS"; then
    :
  elif [[ "$SERVICE_ENABLED_STATUS" == "unknown" ]]; then
    add_warning "Could not determine whether service '$SERVICE_NAME' is enabled for boot under $SERVICE_MANAGER_NORMALIZED."
  else
    add_warning "Service '$SERVICE_NAME' does not appear to be enabled for boot under $SERVICE_MANAGER_NORMALIZED (status: $SERVICE_ENABLED_STATUS)."
  fi
  if [[ "$SERVICE_MANAGER_NORMALIZED" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl show "$SERVICE_NAME" --no-pager \
      --property=Id,LoadState,ActiveState,SubState,UnitFileState,MainPID,ExecMainCode,ExecMainStatus,NRestarts,ActiveEnterTimestamp \
      2>/dev/null || true
  fi
  service_definition_summary
  echo "ServiceDefinitionChecked=$SERVICE_DEFINITION_CHECKED"
  echo "ServiceDefinitionSource=$SERVICE_DEFINITION_SOURCE"
  echo "ServiceDefinitionExists=$SERVICE_DEFINITION_EXISTS"
  echo "ServiceDefinitionNodeExeMatchesConfig=$SERVICE_DEFINITION_NODE_EXE_MATCHES_CONFIG"
  echo "ServiceDefinitionWorkingDirectoryMatchesConfig=$SERVICE_DEFINITION_WORKING_DIRECTORY_MATCHES_CONFIG"
  echo "ServiceDefinitionArgumentsMatchConfig=$SERVICE_DEFINITION_ARGUMENTS_MATCH_CONFIG"
  if [[ "$SERVICE_MANAGER_NORMALIZED" == "launchd" ]]; then
    echo "ServiceDefinitionRunnerScriptMatchesConfig=$SERVICE_DEFINITION_RUNNER_SCRIPT_MATCHES_CONFIG"
  fi
  if [[ "$SERVICE_DEFINITION_EXISTS" != "true" ]]; then
    add_critical "Managed service definition for '$SERVICE_NAME' was not found under $SERVICE_MANAGER_NORMALIZED."
  fi
  if [[ "$SERVICE_DEFINITION_NODE_EXE_MATCHES_CONFIG" != "true" ]]; then
    add_critical "Managed service definition Node executable does not match NODE_BIN."
  fi
  if [[ "$SERVICE_DEFINITION_WORKING_DIRECTORY_MATCHES_CONFIG" != "true" ]]; then
    add_critical "Managed service definition working directory does not match APP_DIR."
  fi
  if [[ "$SERVICE_DEFINITION_ARGUMENTS_MATCH_CONFIG" != "true" ]]; then
    add_critical "Managed service definition command arguments do not match START_SCRIPT/NODE_ARGUMENTS."
  fi
  if [[ "$SERVICE_MANAGER_NORMALIZED" == "launchd" && "$SERVICE_DEFINITION_RUNNER_SCRIPT_MATCHES_CONFIG" != "true" ]]; then
    add_critical "Launchd service plist does not reference the configured runner script."
  fi
fi
service_pid="$(service_main_pid)"
if [[ -n "$service_pid" && "$service_pid" != "0" ]]; then
  echo "ServiceMainPID=$service_pid"
  if uptime_seconds="$(process_elapsed_seconds "$service_pid" 2>/dev/null)"; then
    SERVICE_UPTIME_SECONDS="$uptime_seconds"
    SERVICE_START_KNOWN="true"
    echo "ServiceProcessUptime=$(format_seconds "$uptime_seconds")"
    if is_integer "$MINIMUM_UPTIME_HOURS" && [[ "$MINIMUM_UPTIME_HOURS" -gt 0 ]]; then
      minimum_seconds=$((MINIMUM_UPTIME_HOURS * 3600))
      if [[ "$uptime_seconds" -ge "$minimum_seconds" ]]; then
        UPTIME_MINIMUM_SATISFIED="true"
      else
        UPTIME_MINIMUM_SATISFIED="false"
      fi
      if [[ "$uptime_seconds" -lt "$minimum_seconds" ]]; then
        add_warning "Known service process uptime is below requested minimum of $MINIMUM_UPTIME_HOURS hour(s)."
      fi
    fi
  fi
fi

echo
echo "Port"
if is_true "$SKIP_PORT_CHECK"; then
  PORT_CHECKED="false"
  echo "Port check skipped."
elif [[ -z "${APP_PORT:-}" ]]; then
  PORT_CHECKED="true"
  PORT_LISTENING="false"
  add_critical "APP_PORT is not configured."
else
  PORT_CHECKED="true"
  if port_has_listener "$APP_PORT"; then
    PORT_LISTENING="true"
    echo "ConfiguredPortListening=true"
    mapfile_supported="true"
    owner_pids=""
    if ! owner_pids="$(port_owner_pids "$APP_PORT" | tr '\n' ' ' | sed 's/[[:space:]]*$//' 2>/dev/null)"; then
      mapfile_supported="false"
    fi
    echo "ConfiguredPortOwnerPids=$owner_pids"
    if [[ -n "$owner_pids" ]]; then
      PORT_OWNER_READABLE="true"
      PORT_OWNER_PROCESS_COUNT="$(printf '%s\n' "$owner_pids" | wc -w | tr -d '[:space:]')"
    fi
    if [[ -n "$service_pid" && "$service_pid" != "0" ]]; then
      PORT_SERVICE_PID_KNOWN="true"
    fi
    if [[ -n "$service_pid" && -n "$owner_pids" ]]; then
      case " $owner_pids " in
        *" $service_pid "*)
          PORT_OWNED_BY_SERVICE="true"
          echo "ConfiguredPortOwnedByServiceMainPid=true"
          ;;
        *)
          PORT_OWNED_BY_SERVICE="false"
          add_warning "Configured port owner PID(s) do not include known service main PID $service_pid."
          echo "ConfiguredPortOwnedByServiceMainPid=false"
          ;;
      esac
    elif [[ "$mapfile_supported" == "false" ]]; then
      PORT_OWNER_READABLE="false"
      add_warning "Configured port is listening, but owner PID could not be read on this host."
    elif [[ -z "$service_pid" || "$service_pid" == "0" ]]; then
      PORT_SERVICE_PID_KNOWN="false"
      add_warning "Configured port is listening, but service main PID could not be determined for ownership proof."
    fi
  else
    PORT_LISTENING="false"
    add_critical "No listener was found on configured APP_PORT ${APP_PORT:-}."
    echo "ConfiguredPortListening=false"
  fi
fi

echo
echo "Next.js Runtime Layout"
run_nextjs_layout_check
update_deployment_identity

echo
echo "Deployment Identity"
echo "DeploymentIdentityStatus=$DEPLOYMENT_IDENTITY_STATUS"
echo "AppDirectoryName=$DEPLOYMENT_IDENTITY_APP_DIR_NAME"
echo "DeploymentId=$DEPLOYMENT_IDENTITY_DEPLOYMENT_ID"
echo "NextBuildId=$DEPLOYMENT_IDENTITY_NEXT_BUILD_ID"
echo "ManifestExists=$DEPLOYMENT_IDENTITY_MANIFEST_EXISTS"
echo "PackageName=$DEPLOYMENT_IDENTITY_PACKAGE_NAME"
echo "PackageSha256=$DEPLOYMENT_IDENTITY_PACKAGE_SHA256"
echo "PackageImportedAtUtc=$DEPLOYMENT_IDENTITY_PACKAGE_IMPORTED_AT_UTC"

echo
echo "HTTP Health"
HEALTH_PROBE_URL="${HEALTH_URL:-}"
if is_true "$SKIP_HEALTH_CHECK"; then
  HEALTH_CHECKED="false"
  HEALTH_STATUS="skipped"
  echo "HTTP health check skipped."
elif [[ -z "${HEALTH_URL:-}" ]]; then
  HEALTH_CHECKED="true"
  HEALTH_STATUS="not-configured"
  add_critical "HEALTH_URL is not configured."
else
  HEALTH_CHECKED="true"
  set +e
  health_summary="$(curl -sS -o /dev/null --max-time "$HEALTH_TIMEOUT_SECONDS" -w 'http_code=%{http_code}\ntime_total=%{time_total}\n' "$HEALTH_URL" 2>/dev/null)"
  health_exit=$?
  set -e
  printf '%s\n' "$health_summary"
  echo "curl_exit=$health_exit"
  health_code="$(printf '%s\n' "$health_summary" | awk -F= '$1 == "http_code" { print $2 }')"
  HEALTH_STATUS_CODE="$health_code"
  HEALTH_RESPONSE_SECONDS="$(printf '%s\n' "$health_summary" | awk -F= '$1 == "time_total" { print $2 }')"
  if [[ "$health_exit" -ne 0 ]]; then
    HEALTH_STATUS="failed"
    add_critical "HTTP health probe failed for configured HEALTH_URL."
  elif ! is_integer "$health_code"; then
    HEALTH_STATUS="failed"
    add_critical "HTTP health probe did not return a numeric status code."
  elif [[ "$health_code" -lt 200 || "$health_code" -ge 400 ]]; then
    HEALTH_STATUS="failed"
    add_critical "HTTP health probe returned HTTP $health_code."
  else
    HEALTH_STATUS="ok"
  fi
fi

echo
echo "Reverse Proxy Health"
REVERSE_PROXY_PROBE_URL="$(default_proxy_health_url)"
collect_reverse_proxy_config_evidence
if [[ "$REVERSE_PROXY_CONFIG_APPLICABLE" == "true" ]]; then
  echo "ProxyConfigFile=$REVERSE_PROXY_CONFIG_PATH_NAME"
  echo "ProxyConfigDirectory=$REVERSE_PROXY_CONFIG_DIR_NAME"
  echo "ProxyConfigExists=$REVERSE_PROXY_CONFIG_EXISTS"
  echo "ProxyConfigManagedMarkerFound=$REVERSE_PROXY_CONFIG_MANAGED_MARKER_FOUND"
fi
case "$REVERSE_PROXY_NORMALIZED" in
  ""|none)
    REVERSE_PROXY_APPLICABLE="false"
    REVERSE_PROXY_STATUS="not-applicable"
    echo "Reverse proxy check not applicable."
    ;;
  *)
    REVERSE_PROXY_APPLICABLE="true"
    if [[ -z "$REVERSE_PROXY_PROBE_URL" ]]; then
      REVERSE_PROXY_STATUS="not-configured"
      add_warning "Reverse proxy is '$REVERSE_PROXY_NORMALIZED', but no proxy health probe URL could be determined."
      echo "ReverseProxyStatus=not-configured"
    else
      set +e
      proxy_summary="$(curl -sS -o /dev/null --max-time "$HEALTH_TIMEOUT_SECONDS" -w 'http_code=%{http_code}\ntime_total=%{time_total}\n' "$REVERSE_PROXY_PROBE_URL" 2>/dev/null)"
      proxy_exit=$?
      set -e
      printf '%s\n' "$proxy_summary"
      echo "curl_exit=$proxy_exit"
      echo "ProxyHealthUrl=$(safe_url "$REVERSE_PROXY_PROBE_URL")"
      REVERSE_PROXY_STATUS_CODE="$(printf '%s\n' "$proxy_summary" | awk -F= '$1 == "http_code" { print $2 }')"
      REVERSE_PROXY_RESPONSE_SECONDS="$(printf '%s\n' "$proxy_summary" | awk -F= '$1 == "time_total" { print $2 }')"
      if [[ "$proxy_exit" -ne 0 ]]; then
        REVERSE_PROXY_STATUS="failed"
        add_warning "Reverse proxy health probe failed for configured proxy health URL."
      elif ! is_integer "$REVERSE_PROXY_STATUS_CODE"; then
        REVERSE_PROXY_STATUS="failed"
        add_warning "Reverse proxy health probe did not return a numeric status code."
      elif [[ "$REVERSE_PROXY_STATUS_CODE" -lt 200 || "$REVERSE_PROXY_STATUS_CODE" -ge 400 ]]; then
        REVERSE_PROXY_STATUS="failed"
        add_warning "Reverse proxy health probe returned HTTP $REVERSE_PROXY_STATUS_CODE."
      else
        REVERSE_PROXY_STATUS="ok"
      fi
      echo "ReverseProxyStatus=$REVERSE_PROXY_STATUS"
    fi
    ;;
esac

echo
echo "Health History"
health_scheduler_summary
health_state_summary
health_log_summary
if [[ "$HEALTH_MONITOR_SCHEDULED" == "true" &&
      "$HEALTH_MONITOR_STATE_EXISTS" == "true" &&
      "$HEALTH_MONITOR_LAST_SUCCESS_FRESH" == "true" &&
      "${HEALTH_MONITOR_CONSECUTIVE_FAILURES:-}" == "0" &&
      "$HEALTH_MONITOR_LOG_EXISTS" == "true" &&
      "${HEALTH_MONITOR_LOG_FAILURE_COUNT:-}" == "0" &&
      "${HEALTH_MONITOR_LOG_RESTART_COUNT:-}" == "0" ]]; then
  HEALTH_MONITOR_STATUS="ok"
else
  HEALTH_MONITOR_STATUS="warning"
fi

echo
echo "Operational Verdict"
critical_count=0
warning_count=0
for finding in "${findings[@]}"; do
  severity="${finding%%|*}"
  if [[ "$severity" == "Critical" ]]; then
    critical_count=$((critical_count + 1))
  elif [[ "$severity" == "Warning" ]]; then
    warning_count=$((warning_count + 1))
  fi
done
if [[ "$critical_count" -gt 0 ]]; then
  verdict="Critical"
elif [[ "$warning_count" -gt 0 ]]; then
  verdict="Warning"
else
  verdict="Healthy"
fi
echo "Verdict=$verdict"
echo "Critical=$critical_count"
echo "Warnings=$warning_count"
if [[ "${#findings[@]}" -gt 0 ]]; then
  for finding in "${findings[@]}"; do
    printf '%s: %s\n' "${finding%%|*}" "${finding#*|}"
  done
else
  echo "No critical or warning findings."
fi

if [[ -n "$JSON_OUTPUT" ]]; then
  write_json_output "$JSON_OUTPUT"
fi

if is_true "$FAIL_ON_CRITICAL" && [[ "$critical_count" -gt 0 ]]; then
  exit 2
fi
if is_true "$FAIL_ON_WARNING" && [[ "$warning_count" -gt 0 ]]; then
  exit 3
fi
