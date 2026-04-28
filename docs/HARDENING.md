# Hardening Guide

## Runtime Hardening

- Use a dedicated service account.
- Avoid local administrator/root service execution unless required.
- Bind the Node.js app to `127.0.0.1`.
- Expose only IIS/Nginx/load balancer ports.
- Rotate logs.
- Keep Node.js and dependencies patched.
- Use `npm ci --omit=dev` for deterministic production installs.
- Avoid `npm install` directly in production if a built artifact pipeline exists.

## Windows

- Use WinSW or NSSM, not an interactive PowerShell session.
- Configure Windows Service recovery.
- Use IIS TLS certificates and URL Rewrite/ARR if IIS is the frontend.
- Collect Windows Event Logs into Wazuh or Graylog.
- Restrict write permissions to app and log directories.

## Linux

- Use systemd sandboxing options where possible.
- Use Nginx TLS configuration from your enterprise baseline.
- Use firewall rules to block external access to the Node.js port.
- Collect journald and log files into Wazuh, Graylog, or your logging platform.

## Secrets

Never commit secrets. Use one of:

- Environment files deployed outside Git.
- Ansible Vault.
- HashiCorp Vault.
- Cloud secret manager.
- Windows Credential Manager / DPAPI where suitable.
