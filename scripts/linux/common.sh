#!/usr/bin/env bash

normalize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

detect_os_kernel() {
  uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

detect_os_id_like() {
  local kernel
  kernel="$(detect_os_kernel)"
  case "$kernel" in
    linux)
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${ID_LIKE:-} ${ID:-}" | tr '[:upper:]' '[:lower:]'
      else
        printf '%s\n' "linux"
      fi
      ;;
    darwin)
      printf '%s\n' "darwin macos"
      ;;
    freebsd|openbsd|netbsd)
      printf '%s\n' "$kernel bsd"
      ;;
    *)
      printf '%s\n' "$kernel"
      ;;
  esac
}

detect_platform_family() {
  local id_like
  id_like="$(detect_os_id_like)"
  if echo "$id_like" | grep -Eq 'debian|ubuntu|linuxmint|mint'; then
    echo "debian"
  elif echo "$id_like" | grep -Eq 'rhel|fedora|centos|rocky|almalinux|ol|oracle'; then
    echo "rhel"
  elif echo "$id_like" | grep -Eq 'alpine'; then
    echo "alpine"
  elif echo "$id_like" | grep -Eq 'freebsd'; then
    echo "freebsd"
  elif echo "$id_like" | grep -Eq 'openbsd'; then
    echo "openbsd"
  elif echo "$id_like" | grep -Eq 'netbsd'; then
    echo "netbsd"
  elif echo "$id_like" | grep -Eq 'darwin|macos'; then
    echo "macos"
  else
    echo "unknown"
  fi
}

default_service_manager() {
  local family="${1:-$(detect_platform_family)}"
  case "$family" in
    macos)
      echo "launchd"
      ;;
    freebsd|openbsd|netbsd)
      echo "bsdrc"
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1; then
        echo "systemd"
      elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
      else
        echo "systemv"
      fi
      ;;
  esac
}

service_exists_systemd() {
  local service_name="$1"
  command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${service_name}.service" >/dev/null 2>&1
}

reload_or_restart_service() {
  local service_name="$1" label="${2:-$1}"
  if [[ -z "$service_name" ]]; then
    echo "$label config installed, but no service name was configured. Reload it manually." >&2
  elif service_exists_systemd "$service_name"; then
    systemctl reload "$service_name" || systemctl restart "$service_name"
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "$service_name" reload || rc-service "$service_name" restart
  elif command -v service >/dev/null 2>&1; then
    service "$service_name" reload || service "$service_name" restart
  elif [[ -x "/etc/init.d/$service_name" ]]; then
    "/etc/init.d/$service_name" reload || "/etc/init.d/$service_name" restart
  elif command -v launchctl >/dev/null 2>&1; then
    launchctl kickstart -k "system/$service_name" 2>/dev/null || echo "$label config installed; reload $service_name manually." >&2
  elif command -v rcctl >/dev/null 2>&1; then
    rcctl reload "$service_name" 2>/dev/null || rcctl restart "$service_name" 2>/dev/null || echo "$label config installed; reload $service_name manually." >&2
  else
    echo "$label config installed, but no service control command was found. Reload it manually." >&2
  fi
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

timestamp_utc() {
  date -u +%Y%m%d%H%M%S
}

sed_escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

LAST_BACKUP_PATH=""

backup_file_if_exists() {
  local file_path="$1" backup_dir="${2:-${BACKUP_DIR:-}}"
  LAST_BACKUP_PATH=""
  if [[ ! -f "$file_path" ]]; then
    return 0
  fi
  if [[ -z "$backup_dir" ]]; then
    backup_dir="$(dirname "$file_path")/backups"
  fi

  mkdir -p "$backup_dir"
  chmod 0750 "$backup_dir" 2>/dev/null || true
  local backup_path="$backup_dir/$(basename "$file_path").$(timestamp_utc).$$.bak"
  cp -p "$file_path" "$backup_path"
  LAST_BACKUP_PATH="$backup_path"
  echo "Backed up $file_path to $backup_path"
}

replace_file_with_backup() {
  local source_path="$1" target_path="$2" backup_dir="${3:-${BACKUP_DIR:-}}"
  LAST_BACKUP_PATH=""
  if [[ -f "$target_path" ]] && cmp -s "$source_path" "$target_path"; then
    rm -f "$source_path"
    echo "Unchanged: $target_path"
    return 0
  fi

  backup_file_if_exists "$target_path" "$backup_dir"
  mv "$source_path" "$target_path"
  echo "Updated: $target_path"
}

copy_file_with_backup() {
  local source_path="$1" target_path="$2" backup_dir="${3:-${BACKUP_DIR:-}}"
  if [[ -f "$target_path" ]] && cmp -s "$source_path" "$target_path"; then
    echo "Unchanged: $target_path"
    return 0
  fi

  backup_file_if_exists "$target_path" "$backup_dir"
  cp -p "$source_path" "$target_path"
  echo "Updated: $target_path"
}

restore_file_from_backup() {
  local backup_path="$1" target_path="$2"
  if [[ -n "$backup_path" && -f "$backup_path" ]]; then
    cp -p "$backup_path" "$target_path"
    echo "Restored $target_path from $backup_path"
  elif [[ -f "$target_path" ]]; then
    rm -f "$target_path"
    echo "Removed new file after failed validation: $target_path"
  fi
}

render_template_file() {
  local template="$1" output="$2"
  shift 2

  local sed_args=()
  while [[ "$#" -gt 0 ]]; do
    local token="$1" value="${2:-}"
    shift 2
    sed_args+=(-e "s|{{$token}}|$(sed_escape_replacement "$value")|g")
  done

  mkdir -p "$(dirname "$output")"
  local tmp
  tmp="$(mktemp "${output}.tmp.XXXXXX")"
  sed "${sed_args[@]}" "$template" > "$tmp"
  replace_file_with_backup "$tmp" "$output" "${BACKUP_DIR:-}"
}

require_command() {
  local command_name="$1" help_text="${2:-}"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required. $help_text" >&2
    exit 1
  fi
}

resolve_config_path() {
  local repo_root="$1" config_file="$2"
  if [[ "$config_file" != /* ]]; then
    config_file="$repo_root/$config_file"
  fi
  printf '%s\n' "$config_file"
}
