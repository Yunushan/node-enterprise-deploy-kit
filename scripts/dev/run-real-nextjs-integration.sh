#!/usr/bin/env bash
set -euo pipefail

# Native integration creates OS services and protected recovery state. Run on
# disposable CI hosts, keeping the setup-node runtime across sudo's PATH reset.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node_bin="$(command -v node)"
integration_script="$SCRIPT_DIR/test-real-nextjs-integration.mjs"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) exec "$node_bin" "$integration_script" ;;
esac

environment=("PATH=$PATH")
for name in \
  GITHUB_ACTIONS GITHUB_WORKFLOW GITHUB_JOB GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA \
  NEXTJS_INTEGRATION_RESULT_PATH NEXTJS_INTEGRATION_TARGET NEXTJS_INTEGRATION_EXECUTION \
  NEXTJS_INTEGRATION_RUNNER_ENVIRONMENT NEXTJS_INTEGRATION_TEMP_ROOT \
  NEXTJS_INTEGRATION_COMMAND_TIMEOUT_MS NEXTJS_INTEGRATION_NPM_INSTALL_TIMEOUT_MS \
  NEXTJS_INTEGRATION_NPM_BUILD_TIMEOUT_MS NEXTJS_INTEGRATION_NPM_REGISTRY_TIMEOUT_MS \
  KEEP_REAL_NEXTJS_INTEGRATION NODE_EXTRA_CA_CERTS NODE_USE_SYSTEM_CA \
  RUN_SYSTEMD_SERVICE_INTEGRATION RUN_SYSTEMV_SERVICE_INTEGRATION RUN_OPENRC_SERVICE_INTEGRATION \
  RUN_LAUNCHD_SERVICE_INTEGRATION RUN_APACHE_PROXY_INTEGRATION RUN_NGINX_PROXY_INTEGRATION \
  RUN_HAPROXY_INTEGRATION RUN_TRAEFIK_PROXY_INTEGRATION; do
  if [[ "${!name+x}" == x ]]; then environment+=("$name=${!name}"); fi
done

if [[ "$EUID" -eq 0 ]]; then
  exec env "${environment[@]}" "$node_bin" "$integration_script"
fi
exec sudo --non-interactive env "${environment[@]}" "$node_bin" "$integration_script"
