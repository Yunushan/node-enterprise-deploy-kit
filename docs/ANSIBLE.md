# Ansible Deployment

The Ansible roles use the same local deployment scripts as the manual Windows
and Linux flows. This keeps service behavior, preflight checks, reverse proxy
setup, and health-check registration consistent across one-off and automated
deployments.

## Configure Variables

Copy the example variable file into your inventory or group vars:

```bash
cp config/ansible/group_vars_all.example.yml ansible/group_vars/all.yml
```

Edit values for your environment, but keep private values out of the repository.
The example uses placeholder hostnames, paths, and service names only.

Important controls:

| Variable | Purpose |
|---|---|
| `node_deploy_skip_preflight` | Skip target preflight checks |
| `node_deploy_package_path_windows` | Optional remote Windows `.zip` package to import before service setup |
| `node_deploy_package_path_linux` | Optional remote Linux `.zip`, `.tar.gz`, `.tgz`, or `.tar` package to import before service setup |
| `node_deploy_package_expected_files` | Relative files or directories required after package extraction; leave as `[]` to use framework-aware defaults |
| `node_deploy_package_strip_single_top_level_directory` | Strip a single wrapping archive directory |
| `node_deploy_skip_package_import` | Skip package import even when a package path is configured |
| `node_deploy_allow_port_in_use` | Allow intentional updates while the app port is already listening |
| `node_deploy_skip_install` | Skip dependency install command |
| `node_deploy_skip_build` | Skip build command |
| `node_deploy_skip_reverse_proxy` | Leave IIS/Nginx/Apache config unchanged |
| `node_deploy_skip_health_check` | Leave scheduled health checks unchanged |
| `node_deploy_app_runtime` | `node` service deployment or `tomcat` WAR deployment |
| `node_deploy_app_framework` | `node` for generic Node.js, `nextjs` for Next.js layout validation, `reactjs` for React static build validation |
| `node_deploy_nextjs_deployment_mode` | `standalone` or `next-start` |
| `node_deploy_react_document_root` | Relative React build root containing `index.html`, usually `build` or `dist` |
| `node_deploy_nextjs_require_static_assets` | Require `.next/static` under the standalone runtime root |
| `node_deploy_nextjs_require_public_directory` | Require `public` under the standalone runtime root |
| `node_deploy_windows_auto_download_winsw` | Download pinned WinSW automatically on the Windows target when no source exe is copied |
| `node_deploy_windows_winsw_download_url` | HTTPS URL for the pinned WinSW executable |
| `node_deploy_windows_require_winsw_download_sha256` | Require WinSW SHA256 verification when auto-download or local reuse is used |
| `node_deploy_windows_winsw_download_sha256` | SHA256 digest for WinSW verification |
| `node_deploy_windows_winsw_source` | Controller-side WinSW executable path for WinSW deployments |
| `node_deploy_windows_service_account` | Windows service account, such as `NetworkService`, `LocalService`, a dedicated account, or a gMSA |
| `node_deploy_windows_service_account_password` | Optional password for non-gMSA service accounts; prefer a gMSA |
| `node_deploy_windows_iis_enable_arr_proxy` | Enable IIS ARR proxy mode during IIS reverse proxy setup |
| `node_deploy_windows_iis_require_url_rewrite` | Fail Windows preflight/install when URL Rewrite is missing |
| `node_deploy_windows_iis_require_arr_proxy` | Fail Windows preflight/install when ARR is missing |
| `node_deploy_windows_iis_set_forwarded_headers` | Configure URL Rewrite server variables for `X-Forwarded-*` headers |
| `node_deploy_windows_iis_health_proxy_path` | Public IIS path that proxies to the configured health URL |
| `node_deploy_windows_iis_websocket_support` | Warn when IIS WebSocket Protocol support is missing |
| `node_deploy_windows_iis_proxy_timeout_seconds` | IIS ARR proxy timeout in seconds |
| `node_deploy_windows_backup_dir` | Remote Windows directory for service/proxy/task backups |
| `node_deploy_linux_deploy_dir` | Remote Linux directory for copied deployment scripts/templates |
| `node_deploy_linux_config_path` | Remote Linux rendered deployment env file |
| `node_deploy_linux_backup_dir` | Remote Linux directory for service/proxy/health-check backups |
| `node_deploy_linux_healthcheck_state_dir` | Root-owned Linux health-check state directory |
| `node_deploy_linux_service_manager` | `systemd`, `systemv`, `openrc`, `launchd`, or `bsdrc` |
| `node_deploy_linux_reverse_proxy` | `nginx`, `apache`, `haproxy`, `traefik`, or `none` |
| `node_deploy_linux_proxy_listen_port` | Local Nginx/Apache template listener port |
| `node_deploy_linux_forwarded_proto` | Forwarded public scheme, usually `https` behind upstream TLS |
| `node_deploy_linux_forwarded_port` | Forwarded public port, usually `443` behind upstream TLS |
| `node_deploy_linux_haproxy_config_file` | HAProxy config path rendered by the role |
| `node_deploy_linux_haproxy_allow_main_config_replace` | Explicit opt-in before replacing an existing main HAProxy config |
| `node_deploy_linux_traefik_dynamic_file` | Traefik dynamic file rendered by the role |
| `node_deploy_tomcat_war_file` | WAR artifact path used when `node_deploy_app_runtime: tomcat` |
| `node_deploy_log_retention_days` | Managed log file retention period |
| `node_deploy_backup_retention_days` | Managed backup file retention period |
| `node_deploy_diagnostic_retention_days` | Generated diagnostic bundle retention period |

## Run

Validate repository examples and templates before running the playbook:

```powershell
.\scripts\dev\Test-Repository.ps1
```

Install the Ansible collections used by the roles:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

```bash
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/site.yml
```

Windows targets render `app.config.json`, copy the Windows scripts/templates,
copy a trusted WinSW executable when `node_deploy_windows_winsw_source` is set,
or let the target download the pinned WinSW release when auto-download is
enabled, optionally import a remote `.zip` package, and run `deploy.ps1`.

Unix-like targets render the deployment env file, copy `deploy.sh`, scripts,
and templates, optionally install OS dependencies, optionally import a remote
archive package, then run `deploy.sh`. The
same role can target mainstream Linux, BSD, and macOS hosts when the selected
service manager and package tooling are available on the remote system.

When `node_deploy_package_expected_files` is empty or omitted, the roles render
`server.js`, `.next/BUILD_ID`, and `.next/static` for Next.js `standalone`,
`package.json`, `.next/BUILD_ID`, `.next`, plus
`node_modules/next/dist/bin/next` for Next.js `next-start`, and `server.js` plus
`<node_deploy_react_document_root>/index.html` for React. Set the variable only
when your artifact has additional project-specific paths that must be present.

When `node_deploy_nextjs_deployment_mode: next-start` and
`node_deploy_node_arguments` is empty, the roles render `start -H
<node_deploy_bind_address>` so `next start` runs in production mode and binds
to the same local address targeted by the reverse proxy.

## Safety Notes

For the strictest offline or internal-artifact workflow, set
`node_deploy_windows_auto_download_winsw: false` and set
`node_deploy_windows_winsw_source` to a trusted local artifact path. This
repository does not bundle service-wrapper executables.

Install `ansible/requirements.yml` on control nodes that run the playbook or
local syntax checks. The Windows role uses the `ansible.windows` collection.
The sample `ansible.cfg` files keep SSH host key checking enabled. Use an
inventory-specific override only for disposable lab hosts if your organization
permits it.

Set `node_deploy_linux_install_dependencies: true` only when the playbook is
allowed to modify OS packages. Node.js itself should still come from your
company-approved package source or artifact process.

For Traefik, the static Traefik config must already watch
`node_deploy_linux_traefik_dynamic_dir`. For HAProxy, use a dedicated
`node_deploy_linux_haproxy_config_file` unless this host is intentionally
managed as a single-app HAProxy instance.
