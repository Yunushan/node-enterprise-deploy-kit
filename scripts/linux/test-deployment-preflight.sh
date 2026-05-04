#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${1:-config/linux/app.env}"
shift || true
CONFIG_FILE="$(resolve_config_path "$REPO_ROOT" "$CONFIG_FILE")"

ALLOW_PORT_IN_USE="${ALLOW_PORT_IN_USE:-false}"
SKIP_REVERSE_PROXY="${SKIP_REVERSE_PROXY:-false}"
SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-false}"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --allow-port-in-use) ALLOW_PORT_IN_USE="true" ;;
    --skip-reverse-proxy) SKIP_REVERSE_PROXY="true" ;;
    --skip-health-check) SKIP_HEALTH_CHECK="true" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
PLATFORM_FAMILY="$(detect_platform_family)"
APP_RUNTIME_NORMALIZED="$(normalize_name "${APP_RUNTIME:-node}")"

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
runtime_env_key_list() {
  printf '%s' "${RUNTIME_ENV_KEYS:-}" | tr ',;' '  ' | tr -s ' ' '\n' | sed '/^$/d'
}
is_user_runtime_path() {
  [[ "${1:-}" =~ ^/home/[^/]+/(Desktop|Downloads|Documents)(/|$) || "${1:-}" =~ ^/Users/[^/]+/(Desktop|Downloads|Documents)(/|$) ]]
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

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${NODE_BIN:-}" && ! -x "$NODE_BIN" ]]; then
  add_error "NODE_BIN not found or not executable: $NODE_BIN"
fi
if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${NODE_BIN:-}" && "$NODE_BIN" != /* ]]; then
  add_warning "NODE_BIN is not an absolute path. Use an explicit trusted Node.js path in production."
fi

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${APP_DIR:-}" && ! -d "$APP_DIR" ]]; then
  add_error "APP_DIR not found: $APP_DIR"
fi
for path_name in APP_DIR LOG_DIR ENV_FILE BACKUP_DIR; do
  if is_user_runtime_path "${!path_name:-}"; then
    add_warning "$path_name is under a user desktop/downloads/documents path. Use a service-owned production directory."
  fi
done

if [[ "$APP_RUNTIME_NORMALIZED" == "node" && -n "${APP_DIR:-}" && -d "$APP_DIR" && -n "${START_SCRIPT:-}" ]]; then
  if [[ "$START_SCRIPT" = /* ]]; then
    [[ -f "$START_SCRIPT" ]] || add_error "START_SCRIPT file not found: $START_SCRIPT"
  elif [[ "$START_SCRIPT" != *" "* ]]; then
    [[ -f "$APP_DIR/$START_SCRIPT" ]] || add_error "START_SCRIPT file not found under APP_DIR: $APP_DIR/$START_SCRIPT"
  fi
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
done < <(runtime_env_key_list)
if [[ "${#secret_like_runtime_keys[@]}" -gt 0 ]]; then
  add_warning "RUNTIME_ENV_KEYS contains secret-like key name(s): ${secret_like_runtime_keys[*]}. Keep values out of committed config and prefer a secret manager or target-local private env file."
fi

SERVICE_MANAGER_NORMALIZED="$(normalize_name "${SERVICE_MANAGER:-$(default_service_manager "$PLATFORM_FAMILY")}")"
case "$SERVICE_MANAGER_NORMALIZED" in
  systemd)
    command -v systemctl >/dev/null 2>&1 || add_error "SERVICE_MANAGER=systemd but systemctl was not found."
    ;;
  systemv|sysv|sysvinit|initd|init-d)
    if ! command -v service >/dev/null 2>&1 && [[ ! -x "/etc/init.d/${APP_NAME:-}" ]]; then
      add_warning "System V selected, but service command/init script is not currently available."
    fi
    ;;
  openrc)
    command -v rc-service >/dev/null 2>&1 || add_error "SERVICE_MANAGER=openrc but rc-service was not found."
    command -v rc-update >/dev/null 2>&1 || add_error "SERVICE_MANAGER=openrc but rc-update was not found."
    ;;
  launchd)
    command -v launchctl >/dev/null 2>&1 || add_error "SERVICE_MANAGER=launchd but launchctl was not found."
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
      command -v nginx >/dev/null 2>&1 || add_warning "REVERSE_PROXY=nginx but nginx was not found."
      [[ -n "${NGINX_SITE_NAME:-}" ]] || add_warning "NGINX_SITE_NAME is empty; scripts may use an empty config filename."
      ;;
    apache|httpd)
      if ! command -v apache2ctl >/dev/null 2>&1 && ! command -v httpd >/dev/null 2>&1; then
        add_warning "REVERSE_PROXY=apache but apache2ctl/httpd was not found."
      fi
      ;;
    haproxy)
      command -v haproxy >/dev/null 2>&1 || add_warning "REVERSE_PROXY=haproxy but haproxy was not found."
      ;;
    traefik)
      command -v traefik >/dev/null 2>&1 || add_warning "REVERSE_PROXY=traefik but traefik was not found."
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
