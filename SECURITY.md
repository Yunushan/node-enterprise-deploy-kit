# Security Policy

## Supported Security Model

This project is designed to help deploy Node.js applications safely as managed services. It does not include private secrets, customer data, hostnames, or credentials.

Recommended production controls:

- Run the app as a dedicated non-admin service account.
- Bind Node.js to `127.0.0.1` unless direct exposure is explicitly required.
- Expose only IIS/Nginx/load-balancer ports to users.
- Store secrets outside Git.
- Enable TLS on the public reverse proxy.
- Keep health checks on private localhost endpoints where possible.
- Enable service restart policies and health checks.
- Send logs to Wazuh, Graylog, OpenSearch, or another monitored logging platform.
- Restrict deployment permissions to administrators or CI/CD service accounts.

## Reporting Vulnerabilities

Open a private security advisory or contact the repository maintainer. Do not publish secrets, exploit details, production hostnames, or customer-specific data in public issues.

## Secret Handling

Never commit:

```text
.env
.env.local
.env.production
app.config.json
private keys
API tokens
database passwords
JWT secrets
customer IP addresses
internal hostnames
```

Use the provided `.example` files and create local copies during deployment.

The preflight scripts may warn about secret-like environment key names, but
they do not print the corresponding values.
