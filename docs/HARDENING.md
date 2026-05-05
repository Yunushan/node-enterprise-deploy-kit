# Hardening Guide

## Runtime Hardening

- Use a dedicated service account.
- Avoid local administrator/root service execution unless required.
- Bind the Node.js app to `127.0.0.1`.
- Expose only IIS/Nginx/Apache/load balancer ports.
- Keep health checks pointed at localhost/private app ports, not the public URL.
- Use TLS at the public reverse proxy or at a documented upstream load balancer.
- Rotate logs.
- Keep Node.js and dependencies patched.
- Use `npm ci --omit=dev` for deterministic production installs.
- Avoid `npm install` directly in production if a built artifact pipeline exists.

## Windows

- Use WinSW or NSSM, not an interactive PowerShell session.
- Configure Windows Service recovery.
- Use IIS TLS certificates and URL Rewrite/ARR if IIS is the frontend.
- Prefer `NetworkService`, `LocalService`, a dedicated local/domain account, or
  a gMSA over `LocalSystem`.
- Collect Windows Event Logs into Wazuh or Graylog.
- Restrict write permissions to app and log directories.

## Linux

- Use systemd sandboxing options where possible.
- Run Node.js as a dedicated non-root service user and group.
- Use Nginx or Apache TLS configuration from your enterprise baseline.
- Use firewall rules to block external access to the Node.js port.
- Keep Linux health-check state in a root-owned directory outside app-writable
  log paths.
- Keep Linux diagnostic bundles summary-only unless raw logs are explicitly
  needed for incident response.
- Collect journald and log files into Wazuh, Graylog, or your logging platform.

## Preflight Hardening Warnings

The Windows and Linux preflight checks are intentionally warning-oriented for
security posture issues. They do not print secret values. They warn when:

- Node.js is configured to bind publicly while a reverse proxy is selected.
- Health checks point at a non-loopback host in a reverse-proxy deployment.
- TLS is disabled for a public reverse proxy path.
- Windows service config uses `LocalSystem`.
- Linux service config uses `root`.
- Runtime environment key names look secret-like.
- Runtime paths are under user Desktop, Downloads, or Documents folders.
- Production install commands use `npm install` instead of deterministic
  install or artifact deployment.

## Secrets

Never commit secrets. Use one of:

- Environment files deployed outside Git.
- Ansible Vault.
- HashiCorp Vault.
- Cloud secret manager.
- Windows Credential Manager / DPAPI where suitable.
