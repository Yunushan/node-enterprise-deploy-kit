#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE=""
APP_DIR_OVERRIDE=""
MODE_OVERRIDE=""
START_SCRIPT_OVERRIDE=""
REQUIRE_STATIC_OVERRIDE=""
REQUIRE_PUBLIC_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: bash scripts/linux/test-nextjs-runtime-layout.sh [config.env] [options]

Read-only structural check for a deployed Next.js runtime directory.

Options:
  --config PATH             Linux env config path.
  --app-dir PATH            App directory override.
  --mode MODE               standalone or next-start.
  --start-script PATH       Start script override. Defaults to server.js.
  --require-static          Require .next/static. Default for standalone.
  --no-require-static       Do not require .next/static.
  --require-public          Require public/.
  -h, --help                Show this help.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?--config requires a value}"
      shift 2
      ;;
    --app-dir)
      APP_DIR_OVERRIDE="${2:?--app-dir requires a value}"
      shift 2
      ;;
    --mode)
      MODE_OVERRIDE="${2:?--mode requires a value}"
      shift 2
      ;;
    --start-script)
      START_SCRIPT_OVERRIDE="${2:?--start-script requires a value}"
      shift 2
      ;;
    --require-static)
      REQUIRE_STATIC_OVERRIDE="true"
      shift
      ;;
    --no-require-static)
      REQUIRE_STATIC_OVERRIDE="false"
      shift
      ;;
    --require-public)
      REQUIRE_PUBLIC_OVERRIDE="true"
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

if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"
  app_framework_normalized="$(normalize_name "${APP_FRAMEWORK:-node}")"
  case "$app_framework_normalized" in
    next|nextjs|next-js) ;;
    *)
      echo "APP_FRAMEWORK=${APP_FRAMEWORK:-node}; Next.js runtime layout check is not applicable."
      exit 0
      ;;
  esac
fi

APP_DIR="${APP_DIR_OVERRIDE:-${APP_DIR:-}}"
MODE="$(normalize_name "${MODE_OVERRIDE:-${NEXTJS_DEPLOYMENT_MODE:-standalone}}")"
START_SCRIPT="${START_SCRIPT_OVERRIDE:-${START_SCRIPT:-server.js}}"
NODE_ARGUMENTS="${NODE_ARGUMENTS:-}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
REQUIRE_STATIC="${REQUIRE_STATIC_OVERRIDE:-${NEXTJS_REQUIRE_STATIC_ASSETS:-true}}"
REQUIRE_PUBLIC="${REQUIRE_PUBLIC_OVERRIDE:-${NEXTJS_REQUIRE_PUBLIC_DIR:-false}}"

errors=()
warnings=()
add_error() { errors+=("$1"); }
add_warning() { warnings+=("$1"); }

safe_relative_path() {
  local path="${1//\\//}" part
  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  case "$path" in
    [A-Za-z]:*) return 1 ;;
  esac
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -z "$part" || "$part" == "." ]] && continue
    [[ "$part" != ".." ]] || return 1
  done
  return 0
}

path_exists_text() {
  local path="$1" type="${2:-any}"
  case "$type" in
    file) [[ -f "$path" ]] && echo "true" || echo "false" ;;
    dir) [[ -d "$path" ]] && echo "true" || echo "false" ;;
    *) [[ -e "$path" ]] && echo "true" || echo "false" ;;
  esac
}

argument_tokens_contain_next_start() {
  local tokens=()
  read -r -a tokens <<< "$NODE_ARGUMENTS"
  [[ "${#tokens[@]}" -gt 0 && "${tokens[0]}" == "start" ]]
}

next_start_hostname_argument() {
  local tokens=() i token
  read -r -a tokens <<< "$NODE_ARGUMENTS"
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

if [[ -z "$APP_DIR" ]]; then
  add_error "APP_DIR is required."
fi
case "$MODE" in
  standalone|next-start) ;;
  *) add_error "NEXTJS_DEPLOYMENT_MODE must be standalone or next-start." ;;
esac

runtime_root="$APP_DIR"
start_path=""
if [[ "$MODE" == "standalone" && -n "$APP_DIR" ]]; then
  if [[ -z "$START_SCRIPT" || "$START_SCRIPT" == *" "* ]]; then
    add_error "START_SCRIPT must be a single file path for standalone runtime layout validation."
  elif [[ "$START_SCRIPT" = /* ]]; then
    start_path="$START_SCRIPT"
  elif safe_relative_path "$START_SCRIPT"; then
    start_path="${APP_DIR%/}/$START_SCRIPT"
  else
    add_error "START_SCRIPT must be a safe relative file path."
  fi
  if [[ -n "$start_path" ]]; then
    runtime_root="$(dirname "$start_path")"
  fi
fi

server_path="${start_path:-${runtime_root%/}/server.js}"
next_path="${runtime_root%/}/.next"
build_id_path="${runtime_root%/}/.next/BUILD_ID"
static_path="${runtime_root%/}/.next/static"
public_path="${runtime_root%/}/public"
node_modules_path="${runtime_root%/}/node_modules"
package_json_path="${APP_DIR%/}/package.json"
next_package_path="${APP_DIR%/}/node_modules/next"

cat <<SUMMARY
Mode=$MODE
APP_DIR=$APP_DIR
AppDirectoryExists=$(path_exists_text "$APP_DIR" dir)
RuntimeRoot=$runtime_root
START_SCRIPT=$START_SCRIPT
NODE_ARGUMENTS=$NODE_ARGUMENTS
BIND_ADDRESS=$BIND_ADDRESS
RequiresStaticAssets=$REQUIRE_STATIC
RequiresPublicDirectory=$REQUIRE_PUBLIC
ServerJsExists=$(path_exists_text "$server_path" file)
DotNextExists=$(path_exists_text "$next_path" dir)
BuildIdExists=$(path_exists_text "$build_id_path" file)
StaticAssetsExist=$(path_exists_text "$static_path" dir)
PublicDirectoryExists=$(path_exists_text "$public_path" dir)
NodeModulesExists=$(path_exists_text "$node_modules_path" dir)
PackageJsonExists=$(path_exists_text "$package_json_path" file)
NextPackageExists=$(path_exists_text "$next_package_path" dir)
SUMMARY

if [[ -n "$APP_DIR" && ! -d "$APP_DIR" ]]; then
  add_error "APP_DIR was not found: $APP_DIR"
fi

if [[ "$MODE" == "standalone" ]]; then
  if [[ -n "$start_path" && "$(basename "$start_path")" != "server.js" ]]; then
    add_warning "Next.js standalone deployments normally start the generated server.js file."
  fi
  [[ -z "$start_path" || -f "$server_path" ]] || add_error "Next.js standalone server.js was not found at: $server_path"
  [[ -d "$next_path" ]] || add_error "Next.js standalone runtime root is missing .next: $next_path"
  [[ -f "$build_id_path" ]] || add_error "Next.js standalone runtime root is missing .next/BUILD_ID: $build_id_path"
  if is_true "$REQUIRE_STATIC" && [[ ! -d "$static_path" ]]; then
    add_error "Next.js standalone runtime root is missing .next/static: $static_path"
  fi
  if is_true "$REQUIRE_PUBLIC" && [[ ! -d "$public_path" ]]; then
    add_error "Next.js standalone runtime root is missing public directory: $public_path"
  fi
  [[ -d "$node_modules_path" ]] || add_warning "Next.js standalone runtime root has no node_modules directory. Confirm the artifact includes traced dependencies."
elif [[ "$MODE" == "next-start" ]]; then
  if [[ -z "$START_SCRIPT" || "$START_SCRIPT" == *" "* ]]; then
    add_error "START_SCRIPT must be a single file path for Next.js next-start validation."
  elif [[ "$START_SCRIPT" != /* ]] && ! safe_relative_path "$START_SCRIPT"; then
    add_error "START_SCRIPT must be a safe relative file path for Next.js next-start validation."
  else
    if [[ "$START_SCRIPT" = /* ]]; then
      next_start_script_path="$START_SCRIPT"
    else
      next_start_script_path="${APP_DIR%/}/$START_SCRIPT"
    fi
    [[ -f "$next_start_script_path" ]] || add_error "Next.js next-start START_SCRIPT file was not found: $next_start_script_path"
    normalized_next_start_script_path="${next_start_script_path//\\//}"
    case "$normalized_next_start_script_path" in
      */node_modules/next/*) ;;
      *) add_error "Next.js next-start START_SCRIPT should point to the Next CLI under node_modules/next, for example node_modules/next/dist/bin/next." ;;
    esac
  fi
  if ! argument_tokens_contain_next_start; then
    add_error "Next.js next-start mode requires NODE_ARGUMENTS to start with 'start'. Example: start -H $BIND_ADDRESS"
  fi
  hostname_argument="$(next_start_hostname_argument)"
  if [[ -z "$hostname_argument" ]]; then
    add_error "Next.js next-start mode requires NODE_ARGUMENTS to include '-H $BIND_ADDRESS' or '--hostname $BIND_ADDRESS'."
  elif [[ "$hostname_argument" != "$BIND_ADDRESS" ]]; then
    add_error "Next.js next-start hostname argument '$hostname_argument' must match BIND_ADDRESS '$BIND_ADDRESS'."
  fi
  [[ -f "$package_json_path" ]] || add_error "Next.js next-start mode is missing package.json under APP_DIR."
  [[ -d "${APP_DIR%/}/.next" ]] || add_error "Next.js next-start mode is missing .next under APP_DIR."
  [[ -f "${APP_DIR%/}/.next/BUILD_ID" ]] || add_error "Next.js next-start mode is missing .next/BUILD_ID under APP_DIR."
  [[ -d "$next_package_path" ]] || add_error "Next.js next-start mode is missing node_modules/next under APP_DIR."
fi

if [[ "${#warnings[@]}" -gt 0 ]]; then
  echo "Warnings"
  for warning in "${warnings[@]}"; do echo "WARNING: $warning"; done
fi
if [[ "${#errors[@]}" -gt 0 ]]; then
  echo "Errors" >&2
  for error in "${errors[@]}"; do echo "ERROR: $error" >&2; done
  exit 1
fi

echo "Next.js runtime layout OK."
