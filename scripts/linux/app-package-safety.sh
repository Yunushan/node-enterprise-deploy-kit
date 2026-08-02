#!/usr/bin/env bash
# Package state variables are consumed by scripts that source this helper.
# shellcheck disable=SC2034

PACKAGE_SAFETY_ERROR=""
PACKAGE_ARCHIVE_SIZE_BYTES=0
PACKAGE_ARCHIVE_EXTRACTED_BYTES=0
PACKAGE_ARCHIVE_ENTRY_COUNT=0

package_safety_fail() {
  PACKAGE_SAFETY_ERROR="$1"
  return 1
}

package_safety_validate_integer() {
  local name="$1" value="$2" minimum="$3" maximum="$4" numeric
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    package_safety_fail "$name must be an integer between $minimum and $maximum."
    return 1
  fi
  numeric=$((10#$value))
  if (( numeric < minimum || numeric > maximum )); then
    package_safety_fail "$name must be an integer between $minimum and $maximum."
    return 1
  fi
  return 0
}

package_safety_load_policy() {
  PACKAGE_MAX_ARCHIVE_SIZE_MB="${PACKAGE_MAX_ARCHIVE_SIZE_MB:-2048}"
  PACKAGE_MAX_EXTRACTED_SIZE_MB="${PACKAGE_MAX_EXTRACTED_SIZE_MB:-8192}"
  PACKAGE_MAX_ENTRY_COUNT="${PACKAGE_MAX_ENTRY_COUNT:-200000}"
  PACKAGE_MAX_COMPRESSION_RATIO="${PACKAGE_MAX_COMPRESSION_RATIO:-200}"
  PACKAGE_MINIMUM_FREE_SPACE_MB="${PACKAGE_MINIMUM_FREE_SPACE_MB:-1024}"

  package_safety_validate_integer "PACKAGE_MAX_ARCHIVE_SIZE_MB" "$PACKAGE_MAX_ARCHIVE_SIZE_MB" 1 8388608 || return 1
  package_safety_validate_integer "PACKAGE_MAX_EXTRACTED_SIZE_MB" "$PACKAGE_MAX_EXTRACTED_SIZE_MB" 1 8388608 || return 1
  package_safety_validate_integer "PACKAGE_MAX_ENTRY_COUNT" "$PACKAGE_MAX_ENTRY_COUNT" 1 10000000 || return 1
  package_safety_validate_integer "PACKAGE_MAX_COMPRESSION_RATIO" "$PACKAGE_MAX_COMPRESSION_RATIO" 1 1000000 || return 1
  package_safety_validate_integer "PACKAGE_MINIMUM_FREE_SPACE_MB" "$PACKAGE_MINIMUM_FREE_SPACE_MB" 0 8388608 || return 1

  PACKAGE_MAX_ARCHIVE_SIZE_MB=$((10#$PACKAGE_MAX_ARCHIVE_SIZE_MB))
  PACKAGE_MAX_EXTRACTED_SIZE_MB=$((10#$PACKAGE_MAX_EXTRACTED_SIZE_MB))
  PACKAGE_MAX_ENTRY_COUNT=$((10#$PACKAGE_MAX_ENTRY_COUNT))
  PACKAGE_MAX_COMPRESSION_RATIO=$((10#$PACKAGE_MAX_COMPRESSION_RATIO))
  PACKAGE_MINIMUM_FREE_SPACE_MB=$((10#$PACKAGE_MINIMUM_FREE_SPACE_MB))
  PACKAGE_MAX_ARCHIVE_SIZE_BYTES=$((10#$PACKAGE_MAX_ARCHIVE_SIZE_MB * 1024 * 1024))
  PACKAGE_MAX_EXTRACTED_SIZE_BYTES=$((10#$PACKAGE_MAX_EXTRACTED_SIZE_MB * 1024 * 1024))
  PACKAGE_MINIMUM_FREE_SPACE_BYTES=$((10#$PACKAGE_MINIMUM_FREE_SPACE_MB * 1024 * 1024))
  return 0
}

package_safety_file_size_bytes() {
  local size
  size="$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

package_safety_tar_metrics() {
  LC_ALL=C tar -tvf "$1" 2>/dev/null | awk '
    BEGIN { failed = 0; count = 0; total = 0 }
    NF == 0 { next }
    {
      size = ""
      if ($2 ~ /\// && $3 ~ /^[0-9]+$/) {
        size = $3
      } else if ($2 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/) {
        size = $5
      } else if ($4 ~ /^[0-9]+$/) {
        size = $4
      } else {
        failed = 1
        exit 2
      }
      count++
      total += size
    }
    END {
      if (failed) exit 2
      printf "%.0f %.0f\n", count, total
    }
  '
}

package_safety_zip_metrics() {
  LC_ALL=C unzip -l "$1" 2>/dev/null | awk '
    BEGIN { count = 0; total = 0 }
    $1 ~ /^[0-9]+$/ && $2 ~ /^([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9]-[0-9][0-9]-[0-9][0-9])$/ {
      count++
      total += $1
    }
    END {
      if (count == 0) exit 2
      printf "%.0f %.0f\n", count, total
    }
  '
}

package_safety_inspect_archive() {
  local kind="$1" archive_path="$2" metrics
  if ! PACKAGE_ARCHIVE_SIZE_BYTES="$(package_safety_file_size_bytes "$archive_path")"; then
    package_safety_fail "Unable to determine application package size: $archive_path"
    return 1
  fi
  if (( PACKAGE_ARCHIVE_SIZE_BYTES > PACKAGE_MAX_ARCHIVE_SIZE_BYTES )); then
    package_safety_fail "Application package exceeds PACKAGE_MAX_ARCHIVE_SIZE_MB ($PACKAGE_MAX_ARCHIVE_SIZE_BYTES bytes allowed)."
    return 1
  fi

  case "$kind" in
    tar)
      if ! metrics="$(package_safety_tar_metrics "$archive_path")"; then
        package_safety_fail "Unable to read portable tar entry sizes for package safety validation."
        return 1
      fi
      ;;
    zip)
      if ! metrics="$(package_safety_zip_metrics "$archive_path")"; then
        package_safety_fail "Unable to read zip entry sizes for package safety validation."
        return 1
      fi
      ;;
    *)
      package_safety_fail "Unsupported package kind for resource validation: $kind"
      return 1
      ;;
  esac

  read -r PACKAGE_ARCHIVE_ENTRY_COUNT PACKAGE_ARCHIVE_EXTRACTED_BYTES <<< "$metrics"
  if [[ ! "$PACKAGE_ARCHIVE_ENTRY_COUNT" =~ ^[0-9]+$ || ! "$PACKAGE_ARCHIVE_EXTRACTED_BYTES" =~ ^[0-9]+$ ]]; then
    package_safety_fail "Application package resource metadata is invalid."
    return 1
  fi
  if (( PACKAGE_ARCHIVE_ENTRY_COUNT > PACKAGE_MAX_ENTRY_COUNT )); then
    package_safety_fail "Application package exceeds PACKAGE_MAX_ENTRY_COUNT ($PACKAGE_MAX_ENTRY_COUNT entries allowed)."
    return 1
  fi
  if (( PACKAGE_ARCHIVE_EXTRACTED_BYTES > PACKAGE_MAX_EXTRACTED_SIZE_BYTES )); then
    package_safety_fail "Application package exceeds PACKAGE_MAX_EXTRACTED_SIZE_MB ($PACKAGE_MAX_EXTRACTED_SIZE_BYTES bytes allowed)."
    return 1
  fi
  local ratio_base="$PACKAGE_ARCHIVE_SIZE_BYTES"
  (( ratio_base > 0 )) || ratio_base=1
  if (( PACKAGE_ARCHIVE_EXTRACTED_BYTES > ratio_base * PACKAGE_MAX_COMPRESSION_RATIO )); then
    package_safety_fail "Application package exceeds PACKAGE_MAX_COMPRESSION_RATIO (${PACKAGE_MAX_COMPRESSION_RATIO}:1 allowed)."
    return 1
  fi
  return 0
}

package_safety_existing_path() {
  local path="$1" parent
  while [[ ! -e "$path" ]]; do
    parent="$(dirname "$path")"
    if [[ "$parent" == "$path" ]]; then
      return 1
    fi
    path="$parent"
  done
  printf '%s\n' "$path"
}

package_safety_disk_info() {
  local path existing info device available_blocks
  path="$1"
  existing="$(package_safety_existing_path "$path")" || return 1
  info="$(LC_ALL=C df -Pk "$existing" 2>/dev/null | awk 'END { print $1 "\t" $4 }')" || return 1
  IFS=$'\t' read -r device available_blocks <<< "$info"
  [[ -n "$device" && "$available_blocks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s\n' "$device" "$((10#$available_blocks * 1024))"
}

package_safety_tree_disk_bytes() {
  local blocks
  [[ -e "$1" ]] || { printf '0\n'; return 0; }
  blocks="$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')" || return 1
  [[ "$blocks" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((10#$blocks * 1024))"
}

package_safety_check_volume_capacity() {
  local device="$1" available="$2" workload="$3" context="$4"
  local required
  required=$((workload + PACKAGE_MINIMUM_FREE_SPACE_BYTES))
  if (( available < required )); then
    package_safety_fail "Insufficient free disk space for $context on '$device': $required bytes required, $available bytes available."
    return 1
  fi
  return 0
}

package_safety_assert_capacity() {
  local work_path="$1" app_dir="$2" backup_dir="$3" package_already_staged="${4:-false}"
  local work_info app_info backup_info work_device work_available app_device app_available backup_device backup_available
  local work_workload app_workload backup_workload=0 existing_app_bytes=0

  work_info="$(package_safety_disk_info "$work_path")" || {
    package_safety_fail "Could not determine available disk space for package staging: $work_path"
    return 1
  }
  app_info="$(package_safety_disk_info "$app_dir")" || {
    package_safety_fail "Could not determine available disk space for APP_DIR: $app_dir"
    return 1
  }
  backup_info="$(package_safety_disk_info "$backup_dir")" || {
    package_safety_fail "Could not determine available disk space for BACKUP_DIR: $backup_dir"
    return 1
  }
  IFS=$'\t' read -r work_device work_available <<< "$work_info"
  IFS=$'\t' read -r app_device app_available <<< "$app_info"
  IFS=$'\t' read -r backup_device backup_available <<< "$backup_info"

  work_workload="$PACKAGE_ARCHIVE_EXTRACTED_BYTES"
  if [[ "$package_already_staged" != "true" ]]; then
    work_workload=$((work_workload + PACKAGE_ARCHIVE_SIZE_BYTES))
  fi
  app_workload="$PACKAGE_ARCHIVE_EXTRACTED_BYTES"
  if [[ "$backup_device" != "$app_device" && -e "$app_dir" ]]; then
    existing_app_bytes="$(package_safety_tree_disk_bytes "$app_dir")" || {
      package_safety_fail "Could not determine existing APP_DIR size for backup capacity validation."
      return 1
    }
    backup_workload="$existing_app_bytes"
  fi

  if [[ "$app_device" == "$work_device" ]]; then
    work_workload=$((work_workload + app_workload))
    app_workload=0
  fi
  if (( backup_workload > 0 )); then
    if [[ "$backup_device" == "$work_device" ]]; then
      work_workload=$((work_workload + backup_workload))
      backup_workload=0
    elif [[ "$backup_device" == "$app_device" ]]; then
      app_workload=$((app_workload + backup_workload))
      backup_workload=0
    fi
  fi

  package_safety_check_volume_capacity "$work_device" "$work_available" "$work_workload" "package staging and extraction" || return 1
  if (( app_workload > 0 )); then
    package_safety_check_volume_capacity "$app_device" "$app_available" "$app_workload" "application installation" || return 1
  fi
  if (( backup_workload > 0 )); then
    package_safety_check_volume_capacity "$backup_device" "$backup_available" "$backup_workload" "application backup" || return 1
  fi
  return 0
}

package_safety_tree_logical_bytes() {
  find "$1" -type f -exec sh -c '
    for file do
      wc -c < "$file" || exit 1
    done
  ' sh {} + | awk '{ total += $1 } END { printf "%.0f\n", total + 0 }'
}

package_safety_assert_extracted_tree() {
  local root_path="$1" entry_count logical_bytes
  entry_count="$(find "$root_path" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')" || {
    package_safety_fail "Could not count extracted package entries."
    return 1
  }
  logical_bytes="$(package_safety_tree_logical_bytes "$root_path")" || {
    package_safety_fail "Could not measure extracted package size."
    return 1
  }
  if [[ ! "$entry_count" =~ ^[0-9]+$ || ! "$logical_bytes" =~ ^[0-9]+$ ]]; then
    package_safety_fail "Extracted package resource metadata is invalid."
    return 1
  fi
  if (( entry_count > PACKAGE_MAX_ENTRY_COUNT )); then
    package_safety_fail "Extracted package exceeds PACKAGE_MAX_ENTRY_COUNT ($PACKAGE_MAX_ENTRY_COUNT entries allowed)."
    return 1
  fi
  if (( logical_bytes > PACKAGE_MAX_EXTRACTED_SIZE_BYTES )); then
    package_safety_fail "Extracted package exceeds PACKAGE_MAX_EXTRACTED_SIZE_MB ($PACKAGE_MAX_EXTRACTED_SIZE_BYTES bytes allowed)."
    return 1
  fi
  if (( logical_bytes != PACKAGE_ARCHIVE_EXTRACTED_BYTES )); then
    package_safety_fail "Extracted package size does not match trusted archive metadata."
    return 1
  fi
  return 0
}
