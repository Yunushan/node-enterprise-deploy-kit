#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/linux/common.sh
source "$REPO_ROOT/scripts/linux/common.sh"

CONFIG_FILE="${1:-$REPO_ROOT/config/linux/app.env}"
load_config_file CONFIG_FILE "$REPO_ROOT" "$CONFIG_FILE"

REQUIRE_POST_DEPLOY_HEALTH_CHECK="${REQUIRE_POST_DEPLOY_HEALTH_CHECK:-true}"
POST_DEPLOY_HEALTH_ATTEMPTS="${POST_DEPLOY_HEALTH_ATTEMPTS:-12}"
POST_DEPLOY_HEALTH_DELAY_SECONDS="${POST_DEPLOY_HEALTH_DELAY_SECONDS:-5}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"

if ! is_true "$REQUIRE_POST_DEPLOY_HEALTH_CHECK"; then
  echo "WARNING: Post-deploy HTTP health validation is disabled by configuration." >&2
  exit 0
fi

require_command curl "Install curl or explicitly disable REQUIRE_POST_DEPLOY_HEALTH_CHECK."

if [[ -z "${HEALTH_URL:-}" || ! "$HEALTH_URL" =~ ^https?:// ]]; then
  echo "A valid HTTP or HTTPS HEALTH_URL is required for post-deploy validation." >&2
  exit 1
fi
health_authority="${HEALTH_URL#*://}"
health_authority="${health_authority%%/*}"
if [[ "$health_authority" == *"@"* || "$HEALTH_URL" == *"?"* || "$HEALTH_URL" == *"#"* ]]; then
  echo "HEALTH_URL must not contain credentials, query text, or a fragment." >&2
  exit 1
fi
if [[ "$health_authority" == \[* ]]; then
  health_host="${health_authority#\[}"
  health_host="${health_host%%\]*}"
else
  health_host="${health_authority%%:*}"
fi
health_host="$(printf '%s' "$health_host" | tr '[:upper:]' '[:lower:]')"
if [[ "$health_host" != "localhost" && "$health_host" != "::1" && "$health_host" != "0:0:0:0:0:0:0:1" && ! "$health_host" =~ ^127\. ]]; then
  echo "HEALTH_URL must target a loopback host for privileged post-deploy validation." >&2
  exit 1
fi
for setting_name in POST_DEPLOY_HEALTH_ATTEMPTS POST_DEPLOY_HEALTH_DELAY_SECONDS HEALTHCHECK_TIMEOUT; do
  setting_value="${!setting_name}"
  if [[ ! "$setting_value" =~ ^[0-9]+$ ]]; then
    echo "$setting_name must be a non-negative integer." >&2
    exit 1
  fi
done
if [[ "$POST_DEPLOY_HEALTH_ATTEMPTS" -lt 1 || "$POST_DEPLOY_HEALTH_ATTEMPTS" -gt 120 ]]; then
  echo "POST_DEPLOY_HEALTH_ATTEMPTS must be from 1 through 120." >&2
  exit 1
fi
if [[ "$POST_DEPLOY_HEALTH_DELAY_SECONDS" -gt 300 ]]; then
  echo "POST_DEPLOY_HEALTH_DELAY_SECONDS must be from 0 through 300." >&2
  exit 1
fi
if [[ "$HEALTHCHECK_TIMEOUT" -lt 1 || "$HEALTHCHECK_TIMEOUT" -gt 300 ]]; then
  echo "HEALTHCHECK_TIMEOUT must be from 1 through 300." >&2
  exit 1
fi

last_result="no response"
attempt=1
while [[ "$attempt" -le "$POST_DEPLOY_HEALTH_ATTEMPTS" ]]; do
  http_code=""
  if http_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTH_URL")"; then
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      echo "Post-deploy health check passed with HTTP $http_code on attempt $attempt/$POST_DEPLOY_HEALTH_ATTEMPTS."
      exit 0
    fi
    last_result="HTTP ${http_code:-unknown}"
  else
    curl_exit=$?
    last_result="curl exit $curl_exit: ${http_code:-no HTTP response}"
  fi

  if [[ "$attempt" -lt "$POST_DEPLOY_HEALTH_ATTEMPTS" && "$POST_DEPLOY_HEALTH_DELAY_SECONDS" -gt 0 ]]; then
    sleep "$POST_DEPLOY_HEALTH_DELAY_SECONDS"
  fi
  attempt=$((attempt + 1))
done

echo "Post-deploy health check failed after $POST_DEPLOY_HEALTH_ATTEMPTS attempt(s); last result: $last_result." >&2
exit 1
