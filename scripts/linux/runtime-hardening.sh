#!/usr/bin/env bash

# Shared by privileged monitor/diagnostic entrypoints. Control directories must
# have a trusted owner all the way to the filesystem root; a protected leaf
# under an application-writable parent is not protected.
hardening_path_is_absolute() {
  local path="${1:-}" part
  [[ "$path" == /* && "$path" != "/" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  local -a parts
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ "$part" != "." && "$part" != ".." ]] || return 1
  done
}

hardening_stat() {
  local path="$1"
  stat -c '%u %a' -- "$path" 2>/dev/null || stat -f '%u %Lp' "$path" 2>/dev/null
}

hardening_assert_trusted_directory() {
  local path="$1" current="" part owner mode metadata expected_uid resolved
  expected_uid="${EUID:-$(id -u)}"
  hardening_path_is_absolute "$path" || { echo "Unsafe control directory: $path" >&2; return 1; }
  local -a parts
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    if [[ -L "$current" ]]; then
      # Native systems alias /var/run to /run and Darwin /var to /private/var.
      # A trusted ancestor may use that alias; the managed leaf never may.
      [[ "$current" != "${path%/}" ]] || { echo "Control directory must not be a symlink: $current" >&2; return 1; }
      metadata="$(hardening_stat "$current")" || return 1
      read -r owner mode <<< "$metadata"
      [[ "$owner" == 0 || "$owner" == "$expected_uid" ]] || { echo "Untrusted control directory symlink owner: $current" >&2; return 1; }
      resolved="$(cd -P "$current" && pwd -P)" || return 1
      hardening_assert_trusted_directory "$resolved" || return 1
      continue
    fi
    [[ -e "$current" ]] || continue
    [[ -d "$current" ]] || { echo "Control path is not a directory: $current" >&2; return 1; }
    metadata="$(hardening_stat "$current")" || return 1
    read -r owner mode <<< "$metadata"
    [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]+$ ]] || return 1
    [[ "$owner" == "0" || "$owner" == "$expected_uid" ]] || { echo "Untrusted control directory owner: $current" >&2; return 1; }
    # A root-owned sticky temporary parent cannot be renamed by another user.
    if (( (8#$mode & 0022) != 0 && ! (owner == 0 && (8#$mode & 01000) != 0) )); then
      echo "Control directory is writable by another account: $current" >&2
      return 1
    fi
  done
}

hardening_prepare_control_directory() {
  local path="$1"
  hardening_assert_trusted_directory "$path" || return 1
  (umask 077; mkdir -p -- "$path") || return 1
  hardening_assert_trusted_directory "$path" || return 1
  chmod 0700 -- "$path"
}

# A removed/stale mutex does not prove that the previous deployment completed.
# Any retained journal or package state requires an operator's explicit recovery.
# Call while holding the app mutex; only a validated inherited journal is exempt.
hardening_assert_no_pending_transactions() {
  local lock_path="$1" active_journal="${2:-}" active_package="${3:-}" pending prefix
  local transaction_root="${4:-${DEPLOYMENT_TRANSACTION_ROOT:-/var/lib/node-enterprise-deploy-kit/deployment-transactions}}"
  hardening_path_is_absolute "$lock_path" || return 1
  hardening_assert_trusted_directory "$(dirname "$lock_path")" || return 1
  hardening_assert_trusted_directory "$transaction_root" || return 1
  for prefix in "$lock_path" "${transaction_root%/}/$(basename "$lock_path")"; do
    for pending in "$prefix".managed-transaction.* "$prefix".package-transaction.*.state; do
      [[ -e "$pending" || -L "$pending" ]] || continue
      [[ -z "$active_journal" || "$pending" != "$active_journal" ]] || continue
      [[ -z "$active_package" || "$pending" != "$active_package" ]] || continue
      echo "Unfinished deployment recovery state requires manual recovery before another operation: $pending" >&2
      return 1
    done
  done
}

hardening_assert_control_file() {
  local path="$1" metadata owner mode expected_uid
  expected_uid="${EUID:-$(id -u)}"
  [[ ! -L "$path" ]] || { echo "Control file must not be a symlink: $path" >&2; return 1; }
  [[ ! -e "$path" || -f "$path" ]] || { echo "Control file is not a regular file: $path" >&2; return 1; }
  [[ -e "$path" ]] || return 0
  metadata="$(hardening_stat "$path")" || return 1
  read -r owner mode <<< "$metadata"
  [[ "$owner" == "$expected_uid" && "$mode" =~ ^[0-7]+$ ]] || { echo "Untrusted control file owner: $path" >&2; return 1; }
  (( (8#$mode & 0022) == 0 )) || { echo "Control file is writable by another account: $path" >&2; return 1; }
}

hardening_create_control_file() {
  local path="$1"
  hardening_assert_control_file "$path" || return 1
  if [[ ! -e "$path" ]]; then
    (umask 077; set -o noclobber; : > "$path") || return 1
  fi
  chmod 0600 -- "$path"
}

hardening_rotate_log() {
  local path="$1" maximum_bytes="$2" generations="$3" size index
  hardening_assert_control_file "$path" || return 1
  [[ -f "$path" ]] || return 0
  size="$(wc -c < "$path" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$maximum_bytes" ]] || return 0
  for ((index = generations; index >= 1; index--)); do
    hardening_assert_control_file "$path.$index" || return 1
  done
  rm -f -- "$path.$generations"
  for ((index = generations - 1; index >= 1; index--)); do
    [[ ! -f "$path.$index" ]] || mv -- "$path.$index" "$path.$((index + 1))"
  done
  mv -- "$path" "$path.1"
  hardening_create_control_file "$path"
}

# Native proxies retain their log descriptor. Truncate the trusted root-owned
# inode after copying, with the same bounded loss window as app copytruncate.
hardening_copytruncate_control_log() {
  local path="$1" maximum_bytes="$2" generations="$3" size index
  hardening_assert_control_file "$path" || return 1
  [[ -f "$path" ]] || return 0
  size="$(wc -c < "$path" | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ && "$size" -ge "$maximum_bytes" ]] || return 0
  for ((index = generations; index >= 1; index--)); do hardening_assert_control_file "$path.$index" || return 1; done
  rm -f -- "$path.$generations"
  for ((index = generations - 1; index >= 1; index--)); do
    [[ ! -f "$path.$index" ]] || mv -- "$path.$index" "$path.$((index + 1))"
  done
  (umask 077; cp -p -- "$path" "$path.1") && : > "$path"
}
