#!/usr/bin/env bash
# Protected, write-ahead snapshots of files changed by a deployment.
NODE_DEPLOY_TRANSACTION_DIR="${NODE_DEPLOY_TRANSACTION_DIR:-}"
NODE_DEPLOY_TRANSACTION_RESTORING="${NODE_DEPLOY_TRANSACTION_RESTORING:-false}"

transaction_assert_safe_path() {
  local target="$1" parent
  [[ "$target" == /* && "$target" != "/" && "$target" != */../* && "$target" != */./* &&
     "$target" != */.. && "$target" != */. && "$target" != *$'\n'* && "$target" != *$'\r'* ]] || {
    echo "Unsafe deployment transaction path." >&2; return 1;
  }
  [[ ! -L "$target" ]] || { echo "Managed deployment target must not be a symlink: $target" >&2; return 1; }
  parent="$(dirname "$target")"
  hardening_assert_trusted_directory "$parent"
}

transaction_assert_journal() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" ]] || return 1
  transaction_assert_safe_path "$NODE_DEPLOY_TRANSACTION_DIR" || return 1
  [[ -d "$NODE_DEPLOY_TRANSACTION_DIR" && -f "$NODE_DEPLOY_TRANSACTION_DIR/schema" &&
     "$(cat "$NODE_DEPLOY_TRANSACTION_DIR/schema")" == "node-enterprise-deploy-kit/managed-transaction/v1" ]] || {
    echo "Invalid managed deployment transaction journal." >&2; return 1;
  }
}

transaction_assert_active_journal() {
  transaction_assert_journal || return 1
  case "$NODE_DEPLOY_TRANSACTION_DIR" in
    "$DEPLOYMENT_TRANSACTION_PREFIX".managed-transaction.*|"$DEPLOYMENT_LOCK_PATH".managed-transaction.*) ;;
    *) echo 'Inherited journal is outside the protected application transaction namespaces.' >&2; return 1 ;;
  esac
  [[ -n "${NODE_DEPLOY_APP_LOCK_TOKEN:-}" && -n "${DEPLOYMENT_LOCK_PATH:-}" &&
     -f "$NODE_DEPLOY_TRANSACTION_DIR/app-lock-token" && -f "$NODE_DEPLOY_TRANSACTION_DIR/app-lock-path" ]] &&
    grep -Fxq -- "$NODE_DEPLOY_APP_LOCK_TOKEN" "$NODE_DEPLOY_TRANSACTION_DIR/app-lock-token" &&
    grep -Fxq -- "$DEPLOYMENT_LOCK_PATH" "$NODE_DEPLOY_TRANSACTION_DIR/app-lock-path" || {
      echo 'The inherited journal does not belong to the currently held application lock.' >&2
      return 1
    }
}

transaction_begin() {
  local directory="$1"
  if [[ -n "${DEPLOYMENT_LOCK_PATH:-}" ]]; then
    hardening_assert_no_pending_transactions "$DEPLOYMENT_LOCK_PATH" "" "" "$DEPLOYMENT_TRANSACTION_ROOT" || return 1
  fi
  transaction_assert_safe_path "$directory" || return 1
  [[ ! -e "$directory" ]] || { echo "Deployment transaction directory already exists." >&2; return 1; }
  (umask 077; mkdir "$directory" && printf '%s\n' 'node-enterprise-deploy-kit/managed-transaction/v1' > "$directory/schema")
  NODE_DEPLOY_TRANSACTION_DIR="$directory"
  NODE_DEPLOY_TRANSACTION_RESTORING=false
  export NODE_DEPLOY_TRANSACTION_DIR NODE_DEPLOY_TRANSACTION_RESTORING
  if [[ -n "${DEPLOYMENT_LOCK_PATH:-}" ]]; then
    (umask 077
      printf '%s\n' "$DEPLOYMENT_LOCK_PATH" > "$directory/app-lock-path"
      printf '%s\n' "$NODE_DEPLOY_APP_LOCK_TOKEN" > "$directory/app-lock-token"
    )
  fi
}

transaction_record_file() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" && "$NODE_DEPLOY_TRANSACTION_RESTORING" != true ]] || return 0
  transaction_assert_journal || return 1
  local target="$1" entry next=0 existing
  if [[ -L "$target" ]]; then transaction_record_symlink "$target"; return; fi
  transaction_assert_safe_path "$target" || return 1
  [[ ! -e "$target" || -f "$target" ]] || { echo "Managed file target is not a regular file: $target" >&2; return 1; }
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/file.*; do
    [[ -d "$entry" ]] || continue
    existing="$(cat "$entry/path")"
    [[ "$existing" != "$target" ]] || return 0
    next=$((next + 1))
  done
  entry="$NODE_DEPLOY_TRANSACTION_DIR/file.$next"
  (umask 077
    mkdir "$entry"
    printf '%s\n' "$target" > "$entry/path"
    if [[ -f "$target" ]]; then
      cp -p "$target" "$entry/content"
      printf '%s\n' true > "$entry/existed"
    else
      printf '%s\n' false > "$entry/existed"
    fi
    printf '%s\n' complete > "$entry/ready"
  )
}

transaction_extract_cron_block() {
  local input="$1" output="$2" app="$3"
  awk -v start="# node-enterprise-deploy-kit:$app:healthcheck:start" \
      -v end="# node-enterprise-deploy-kit:$app:healthcheck:end" \
      '$0 == start {inside=1} inside {print} $0 == end {inside=0}' "$input" > "$output"
}

transaction_record_root_crontab() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" && "$NODE_DEPLOY_TRANSACTION_RESTORING" != true ]] || return 0
  transaction_assert_journal || return 1
  [[ "$APP_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ ! -f "$NODE_DEPLOY_TRANSACTION_DIR/cron.app" ]] || return 0
  local current="$NODE_DEPLOY_TRANSACTION_DIR/cron.current"
  (umask 077; crontab -l > "$current" 2>/dev/null || : > "$current")
  transaction_extract_cron_block "$current" "$NODE_DEPLOY_TRANSACTION_DIR/cron.block" "$APP_NAME"
  printf '%s\n' "$APP_NAME" > "$NODE_DEPLOY_TRANSACTION_DIR/cron.app"
  rm -f "$current"
}

transaction_restore_root_crontab() {
  [[ -f "$NODE_DEPLOY_TRANSACTION_DIR/cron.app" ]] || return 0
  local app current restored
  app="$(cat "$NODE_DEPLOY_TRANSACTION_DIR/cron.app")"
  [[ "$app" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  current="$(mktemp "$NODE_DEPLOY_TRANSACTION_DIR/cron.restore.XXXXXX")"
  restored="$(mktemp "$NODE_DEPLOY_TRANSACTION_DIR/cron.merged.XXXXXX")"
  crontab -l > "$current" 2>/dev/null || : > "$current"
  awk -v start="# node-enterprise-deploy-kit:$app:healthcheck:start" \
      -v end="# node-enterprise-deploy-kit:$app:healthcheck:end" \
      '$0 == start {inside=1; next} $0 == end {inside=0; next} !inside {print}' "$current" > "$restored"
  cat "$NODE_DEPLOY_TRANSACTION_DIR/cron.block" >> "$restored"
  crontab "$restored"
  rm -f "$current" "$restored"
}

transaction_restore_files() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" ]] || return 0
  transaction_assert_journal || return 1
  local entry target existed temporary count=0 index
  export NODE_DEPLOY_TRANSACTION_RESTORING=true
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/file.*; do
    [[ -d "$entry" ]] || continue
    count=$((count + 1))
  done
  index=$((count - 1))
  while [[ "$index" -ge 0 ]]; do
    entry="$NODE_DEPLOY_TRANSACTION_DIR/file.$index"
    [[ -f "$entry/ready" && "$(cat "$entry/ready")" == complete ]] || {
      echo "Incomplete deployment snapshot; recovery journal retained." >&2; return 1;
    }
    target="$(cat "$entry/path")"
    existed="$(cat "$entry/existed")"
    transaction_assert_safe_path "$target" || return 1
    case "$existed" in
      true)
        [[ -f "$entry/content" ]] || return 1
        mkdir -p "$(dirname "$target")"
        temporary="$(mktemp "$target.restore.XXXXXX")"
        cp -p "$entry/content" "$temporary" && mv -f "$temporary" "$target" || return 1
        ;;
      false)
        [[ ! -e "$target" || -f "$target" ]] || return 1
        rm -f "$target" || return 1
        ;;
      *) return 1 ;;
    esac
    index=$((index - 1))
  done
  transaction_restore_symlinks || return 1
  transaction_restore_registration || return 1
  transaction_restore_root_crontab || return 1
  if declare -F transaction_restore_rc_settings >/dev/null; then transaction_restore_rc_settings; fi
}

transaction_finish() {
  transaction_assert_journal || return 1
  local directory="$NODE_DEPLOY_TRANSACTION_DIR"
  [[ "$(basename "$directory")" == *.managed-transaction.* ]] || {
    echo "Refusing to remove a transaction directory with an unexpected name." >&2; return 1;
  }
  rm -rf -- "$directory"
  NODE_DEPLOY_TRANSACTION_DIR=""
  NODE_DEPLOY_TRANSACTION_RESTORING=false
}

# rc.conf is shared with other services. Snapshot only this service's variable,
# or its membership in OpenBSD's pkg_scripts, and merge it back on recovery.
transaction_rc_pkg_scripts() {
  local input="$1" line value="" token
  local quoted_double='^[[:space:]]*pkg_scripts[[:space:]]*=[[:space:]]*"([A-Za-z0-9_.[:space:]-]*)"[[:space:]]*(#.*)?$'
  local quoted_single="^[[:space:]]*pkg_scripts[[:space:]]*=[[:space:]]*'([A-Za-z0-9_.[:space:]-]*)'[[:space:]]*(#.*)?$"
  local unquoted='^[[:space:]]*pkg_scripts[[:space:]]*=[[:space:]]*([A-Za-z0-9_.[:space:]-]*)[[:space:]]*(#.*)?$'
  [[ -f "$input" ]] || { printf '\n'; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*pkg_scripts[[:space:]]*= ]] || continue
    if [[ "$line" =~ $quoted_double || "$line" =~ $quoted_single || "$line" =~ $unquoted ]]; then
      value="${BASH_REMATCH[1]}"
    else
      echo "Cannot safely journal a dynamic pkg_scripts assignment in $input." >&2
      return 1
    fi
  done < "$input"
  for token in $value; do
    [[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s ' "$token"
  done
  printf '\n'
}

transaction_record_rc_setting() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" && "${NODE_DEPLOY_TRANSACTION_RESTORING:-false}" != true ]] || return 0
  transaction_assert_journal || return 1
  local target="$1" key="$2" entry next=0 existing_path existing_key members token enabled=false
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Invalid rc setting name." >&2; return 1; }
  transaction_assert_safe_path "$target" || return 1
  [[ ! -e "$target" || -f "$target" ]] || return 1
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/rc.*; do
    [[ -d "$entry" ]] || continue
    existing_path="$(cat "$entry/path")"; existing_key="$(cat "$entry/key")"
    [[ "$existing_path" != "$target" || "$existing_key" != "$key" ]] || return 0
    next=$((next + 1))
  done
  if [[ "$key" == pkg_scripts ]]; then
    [[ "${APP_NAME:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    members="$(transaction_rc_pkg_scripts "$target")" || return 1
    for token in $members; do [[ "$token" != "$APP_NAME" ]] || enabled=true; done
  fi
  entry="$NODE_DEPLOY_TRANSACTION_DIR/rc.$next"
  (umask 077
    mkdir "$entry" || exit 1
    printf '%s\n' "$target" > "$entry/path"
    printf '%s\n' "$key" > "$entry/key"
    if [[ "$key" == pkg_scripts ]]; then
      printf '%s\n' "$APP_NAME" > "$entry/app"
      printf '%s\n' "$enabled" > "$entry/enabled"
    elif [[ -f "$target" ]]; then
      awk -v key="$key" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {print}' "$target" > "$entry/assignments"
    else
      : > "$entry/assignments"
    fi
    printf '%s\n' complete > "$entry/ready"
  )
}

transaction_restore_rc_settings() {
  local entry target key temporary app enabled members token restored_members
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/rc.*; do
    [[ -d "$entry" ]] || continue
    [[ -f "$entry/ready" && "$(cat "$entry/ready")" == complete ]] || return 1
    target="$(cat "$entry/path")"; key="$(cat "$entry/key")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    transaction_assert_safe_path "$target" || return 1
    [[ ! -e "$target" || -f "$target" ]] || return 1
    mkdir -p "$(dirname "$target")" || return 1
    temporary="$(mktemp "$target.restore.XXXXXX")" || return 1
    # Keep current file metadata and all unrelated settings, including changes
    # made by an administrator after deployment began.
    if [[ -f "$target" ]]; then cp -p "$target" "$temporary" || return 1; fi
    if [[ "$key" == pkg_scripts ]]; then
      app="$(cat "$entry/app")"; enabled="$(cat "$entry/enabled")"
      [[ "$app" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ( "$enabled" == true || "$enabled" == false ) ]] || return 1
      members="$(transaction_rc_pkg_scripts "$target")" || { rm -f "$temporary"; return 1; }
      restored_members=""
      for token in $members; do
        [[ "$token" == "$app" ]] || restored_members="${restored_members}${restored_members:+ }$token"
      done
      [[ "$enabled" != true ]] || restored_members="${restored_members}${restored_members:+ }$app"
      if [[ -f "$target" ]]; then awk '$0 !~ "^[[:space:]]*pkg_scripts[[:space:]]*=" {print}' "$target" > "$temporary"; else : > "$temporary"; fi
      [[ -z "$restored_members" ]] || printf 'pkg_scripts="%s"\n' "$restored_members" >> "$temporary"
    else
      [[ -f "$entry/assignments" ]] || return 1
      if [[ -f "$target" ]]; then awk -v key="$key" '$0 !~ "^[[:space:]]*" key "[[:space:]]*=" {print}' "$target" > "$temporary"; else : > "$temporary"; fi
      cat "$entry/assignments" >> "$temporary" || return 1
    fi
    mv -f "$temporary" "$target" || return 1
  done
}

transaction_record_symlink() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" && "$NODE_DEPLOY_TRANSACTION_RESTORING" != true ]] || return 0
  transaction_assert_journal || return 1
  local target="$1" entry next=0
  transaction_assert_safe_path "$(dirname "$target")" || return 1
  if [[ -e "$target" && ! -L "$target" ]]; then transaction_record_file "$target"; return; fi
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/link.*; do
    [[ -d "$entry" ]] || continue
    [[ "$(cat "$entry/path")" != "$target" ]] || return 0
    next=$((next + 1))
  done
  entry="$NODE_DEPLOY_TRANSACTION_DIR/link.$next"
  (umask 077; mkdir "$entry" && printf '%s\n' "$target" > "$entry/path"
    if [[ -L "$target" ]]; then readlink "$target" > "$entry/target"; fi
    printf '%s\n' complete > "$entry/ready")
}

transaction_restore_symlinks() {
  local entry target
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/link.*; do
    [[ -d "$entry" ]] || continue
    [[ "$(cat "$entry/ready")" == complete ]] || return 1
    target="$(cat "$entry/path")"
    transaction_assert_safe_path "$(dirname "$target")" || return 1
    [[ ! -e "$target" || -L "$target" || -f "$target" ]] || return 1
    if [[ -f "$target" && ! -L "$target" ]]; then hardening_assert_control_file "$target" || return 1; fi
    rm -f "$target" || return 1
    if [[ -f "$entry/target" ]]; then ln -s "$(cat "$entry/target")" "$target" || return 1; fi
  done
}

transaction_registration_paths() {
  local root="$1" kind="$2" app="$3" directory link canonical
  case "$kind" in
    sysv)
      for directory in "$root"/rc[0-6S].d "$root"/rc.d/rc[0-6S].d; do
        [[ -d "$directory" ]] || continue
        canonical="$(cd -P "$directory" && pwd -P)" || return 1
        transaction_assert_safe_path "$canonical" || return 1
        for link in "$canonical"/[SK][0-9][0-9]"$app"; do [[ ! -L "$link" ]] || printf '%s\n' "$link"; done
      done ;;
    openrc)
      for directory in "$root"/runlevels/*; do
        [[ -d "$directory" ]] || continue
        canonical="$(cd -P "$directory" && pwd -P)" || return 1
        transaction_assert_safe_path "$canonical" || return 1
        link="$canonical/$app"; [[ ! -L "$link" ]] || printf '%s\n' "$link"
      done ;;
    systemd)
      for directory in "$root" "$root"/*.wants "$root"/*.requires; do
        [[ -d "$directory" ]] || continue
        transaction_assert_safe_path "$directory" || return 1
        link="$directory/$app"; [[ ! -L "$link" ]] || printf '%s\n' "$link"
      done ;;
    *) return 1 ;;
  esac
}

transaction_record_registration() {
  [[ -n "$NODE_DEPLOY_TRANSACTION_DIR" && "$NODE_DEPLOY_TRANSACTION_RESTORING" != true ]] || return 0
  transaction_assert_journal || return 1
  local root="$1" kind="$2" app="$3" entry next=0 link index=0
  [[ "$app" =~ ^[A-Za-z0-9_.-]+$ && ( "$kind" == sysv || "$kind" == openrc || "$kind" == systemd ) ]] || return 1
  transaction_assert_safe_path "$root" || return 1
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/registration.*; do
    [[ -d "$entry" ]] || continue
    [[ "$(cat "$entry/root")" != "$root" || "$(cat "$entry/kind")" != "$kind" || "$(cat "$entry/app")" != "$app" ]] || return 0
    next=$((next + 1))
  done
  entry="$NODE_DEPLOY_TRANSACTION_DIR/registration.$next"
  (umask 077; mkdir "$entry"
    printf '%s\n' "$root" > "$entry/root"; printf '%s\n' "$kind" > "$entry/kind"; printf '%s\n' "$app" > "$entry/app"
    transaction_registration_paths "$root" "$kind" "$app" > "$entry/original.links" || exit 1
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      printf '%s\n' "$link" > "$entry/path.$index"
      readlink "$link" > "$entry/target.$index" || exit 1
      index=$((index + 1))
    done < "$entry/original.links"
    printf '%s\n' complete > "$entry/ready")
}

transaction_restore_registration() {
  local entry root kind app link saved
  for entry in "$NODE_DEPLOY_TRANSACTION_DIR"/registration.*; do
    [[ -d "$entry" ]] || continue
    [[ "$(cat "$entry/ready")" == complete ]] || return 1
    root="$(cat "$entry/root")"; kind="$(cat "$entry/kind")"; app="$(cat "$entry/app")"
    transaction_assert_safe_path "$root" || return 1
    [[ "$app" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    transaction_registration_paths "$root" "$kind" "$app" > "$entry/current.links" || return 1
    while IFS= read -r link; do [[ -z "$link" ]] || rm -f "$link" || return 1; done < "$entry/current.links"
    for saved in "$entry"/path.*; do
      [[ -f "$saved" ]] || continue
      link="$(cat "$saved")"
      transaction_assert_safe_path "$(dirname "$link")" || return 1
      [[ ! -e "$link" || -L "$link" || -f "$link" ]] || return 1
      if [[ -f "$link" && ! -L "$link" ]]; then hardening_assert_control_file "$link" || return 1; fi
      rm -f "$link" && ln -s "$(cat "$entry/target.${saved##*.}")" "$link" || return 1
    done
  done
}
