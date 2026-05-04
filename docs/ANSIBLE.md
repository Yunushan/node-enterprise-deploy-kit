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
| `node_deploy_allow_port_in_use` | Allow intentional updates while the app port is already listening |
| `node_deploy_skip_install` | Skip dependency install command |
| `node_deploy_skip_build` | Skip build command |
| `node_deploy_skip_reverse_proxy` | Leave IIS/Nginx/Apache config unchanged |
| `node_deploy_skip_health_check` | Leave scheduled health checks unchanged |
| `node_deploy_app_runtime` | `node` service deployment or `tomcat` WAR deployment |
| `node_deploy_windows_winsw_source` | Controller-side WinSW executable path for WinSW deployments |
| `node_deploy_windows_backup_dir` | Remote Windows directory for service/proxy/task backups |
| `node_deploy_linux_deploy_dir` | Remote Linux directory for copied deployment scripts/templates |
| `node_deploy_linux_config_path` | Remote Linux rendered deployment env file |
| `node_deploy_linux_backup_dir` | Remote Linux directory for service/proxy/health-check backups |
| `node_deploy_linux_service_manager` | `systemd`, `systemv`, `openrc`, `launchd`, or `bsdrc` |
| `node_deploy_linux_reverse_proxy` | `nginx`, `apache`, `haproxy`, `traefik`, or `none` |
| `node_deploy_linux_haproxy_config_file` | HAProxy config path rendered by the role |
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

```bash
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/site.yml
```

Windows targets render `app.config.json`, copy the Windows scripts/templates,
copy the trusted WinSW executable when needed, and run `deploy.ps1`.

Unix-like targets render the deployment env file, copy `deploy.sh`, scripts,
and templates, optionally install OS dependencies, then run `deploy.sh`. The
same role can target mainstream Linux, BSD, and macOS hosts when the selected
service manager and package tooling are available on the remote system.

## Safety Notes

Set `node_deploy_windows_winsw_source` to a trusted local artifact path; this
repository does not bundle service-wrapper executables.

Set `node_deploy_linux_install_dependencies: true` only when the playbook is
allowed to modify OS packages. Node.js itself should still come from your
company-approved package source or artifact process.

For Traefik, the static Traefik config must already watch
`node_deploy_linux_traefik_dynamic_dir`. For HAProxy, use a dedicated
`node_deploy_linux_haproxy_config_file` unless this host is intentionally
managed as a single-app HAProxy instance.
