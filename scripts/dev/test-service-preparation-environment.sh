#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
mkdir -p "$REPO_ROOT/.tmp"
TEST_ROOT="$(mktemp -d "$REPO_ROOT/.tmp/service-preparation-env.XXXXXX")"
cleanup() { [[ "$TEST_ROOT" == "$REPO_ROOT/.tmp/service-preparation-env."* ]] && rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"
sed -n '/^run_as_service_user() {/,/^}/p; /^load_preparation_environment() {/,/^}/p; /^finish_node_service_install() {/,/^}/p' \
  "$REPO_ROOT/scripts/linux/install-node-service.sh" > "$TEST_ROOT/functions.sh"
# Execute the actual installer functions with only account switching mocked.
# shellcheck disable=SC1090,SC1091
source "$TEST_ROOT/functions.sh"
SERVICE_USER=fixture-user
APP_DIR='/fixture app'
printf '%s\n' 'ONE=value with spaces' 'TWO=$(never-execute);literal' > "$TEST_ROOT/preparation.env"
command() {
  if [[ "$1" == -v && "$2" == runuser ]]; then [[ "$branch" == runuser ]];
  elif [[ "$1" == -v && "$2" == su ]]; then return 0;
  else builtin command "$@"; fi
}
runuser() { [[ "$1" == -u && "$2" == "$SERVICE_USER" && "$3" == -- ]] || return 1; shift 3; "$@"; }
env() { printf '%s\n' "$@" > "$TEST_ROOT/arguments"; }
for branch in runuser macos linux; do
  export PLATFORM_FAMILY="$branch"
  for preparation in empty populated; do
    export PREPARATION_ENV_FILE=''
    [[ "$preparation" != populated ]] || PREPARATION_ENV_FILE="$TEST_ROOT/preparation.env"
    load_preparation_environment
    run_as_service_user 'touch stdout.log' 'preparation environment fixture'
    actual=()
    while IFS= read -r argument; do actual+=("$argument"); done < "$TEST_ROOT/arguments"
    case "$branch" in runuser) base_count=3; executable=bash ;; macos) base_count=5; executable=su ;; linux) base_count=7; executable=su ;; esac
    if [[ "$preparation" == empty ]]; then
      [[ ${#actual[@]} -eq "$base_count" && "${actual[0]}" == "$executable" ]]
    else
      [[ ${#actual[@]} -eq $((base_count + 2)) && "${actual[0]}" == 'ONE=value with spaces' && "${actual[1]}" == 'TWO=$(never-execute);literal' && "${actual[2]}" == "$executable" ]]
    fi
  done
done
cat > "$TEST_ROOT/exit-guard.sh" <<'GUARD'
set -eu
source "$1/functions.sh"
NODE_SERVICE_INSTALL_COMPLETE=false
managed_mutation_exit() { printf '%s\n' "$1" > "$guard_root/exit-status"; exit "$1"; }
guard_root="$1"
trap 'finish_node_service_install $?' EXIT
case "$2" in
  success) NODE_SERVICE_INSTALL_COMPLETE=true ;;
  failure) unset NODEKIT_MISSING_VARIABLE; : "$NODEKIT_MISSING_VARIABLE" ;;
  status) exit 37 ;;
esac
GUARD
if "$BASH" "$TEST_ROOT/exit-guard.sh" "$TEST_ROOT" failure > "$TEST_ROOT/guard-output" 2>&1; then echo 'Installer expansion abort was committed as success.' >&2; exit 1; fi
[[ "$(cat "$TEST_ROOT/exit-status")" != 0 ]]
"$BASH" "$TEST_ROOT/exit-guard.sh" "$TEST_ROOT" success
[[ "$(cat "$TEST_ROOT/exit-status")" == 0 ]]
if "$BASH" "$TEST_ROOT/exit-guard.sh" "$TEST_ROOT" status; then echo 'Installer error status was lost.' >&2; exit 1; fi
[[ "$(cat "$TEST_ROOT/exit-status")" == 37 ]]
echo 'Service preparation environment preserves empty arrays and literal values on runuser, macOS su and Linux su paths.'
