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
- Pin third-party GitHub Actions to reviewed immutable commit SHAs.

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

## CI Supply Chain

The support-evidence validators treat host operators, collector hosts, and the
private evidence workspace as trusted. Hashes detect inconsistent or altered
contents relative to a manifest; JSON fields such as `liveHost`, collector
digest, workflow name, and run ID are declarations, not cryptographic
attestations. Obtain evidence directly from authorized hosts and verify the
originating GitHub run and downloaded artifact in the release review. A
redacted readiness summary alone cannot authenticate a private bundle.

Strict release readiness rejects end-of-life or unreviewed Node.js release
lines using `config/node-runtime-policy.json`. The Next.js Node.js 20.9
compatibility floor does not imply Node.js 20 remains supported for production.
Use Node.js 24 LTS by default and vendor-maintained operating systems. Node.js
22 and 26 also receive integration coverage; platform floors vary by release
line and architecture.

The real Next.js fixture uses the reviewed manifest and lockfile in
`tests/fixtures/nextjs`, installs with `npm ci --ignore-scripts`, and receives a
moderate-or-higher npm vulnerability gate. CI also audits the hash-locked
Python tooling and runs checksum-pinned Gitleaks across Git history. Review
Dependabot updates to these dependencies as well as GitHub Actions. Update
`config/nextjs-integration-versions.json` with the fixture manifest and lockfile;
the repository verifier rejects version drift between them.

External GitHub Actions are pinned to immutable commit SHAs with a readable
major-version comment. Dependabot proposes grouped weekly SHA updates; review
the upstream release and commit before merging those pull requests. Run
`scripts/dev/Test-GitHubActionsSecurity.ps1` to reject mutable action tags,
unreviewed external actions, broad workflow write permissions, or a missing
GitHub Actions update policy.
