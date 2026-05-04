# Release Checklist

Use this checklist before deploying the kit changes to a real host.

## Repository Verification

Run the same verification script used by CI:

```powershell
.\scripts\dev\Test-Repository.ps1
```

The verifier checks:

- PowerShell parser errors in `.ps1` files
- Bash syntax for Linux and dev shell scripts
- LF-only line endings for Linux scripts, Linux env examples, and Linux templates
- Windows JSON example config shape
- Linux env example shape
- Ansible example variable coverage
- plain token template rendering with unresolved-token detection
- rendered XML validity for Windows templates
- rendered shell syntax for Linux init templates when `bash` is available
- release package hygiene and required release files
- local docs links, README anchors, and documented entrypoint presence
- obvious committed secret patterns
- `git diff --check` whitespace problems

On Windows, install Git Bash or another `bash` executable for the shell syntax
step. If you are only checking Windows scripts on a restricted machine, use:

```powershell
.\scripts\dev\Test-Repository.ps1 -SkipShellSyntax
```

Ansible playbook syntax is checked automatically when `ansible-playbook` is
available. If Ansible or the required collections are not installed on the
validation machine, that optional check is skipped. CI installs `ansible-core`
and `ansible/requirements.yml` before repository verification so the playbook
syntax check runs deterministically in GitHub Actions.

## Release Package

Build a sanitized source package from tracked and non-ignored release files:

```powershell
.\scripts\dev\Test-ReleasePackage.ps1
.\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0
```

The package builder writes output under `.tmp/release` and creates a manifest
next to the zip. It blocks private configs, local environment files, logs,
build output, external service-wrapper binaries, certificates, and key files.

Use `-NoZip` when you only want a staging directory for inspection:

```powershell
.\scripts\dev\New-ReleasePackage.ps1 -Version 1.0.0 -NoZip
```

## Private Config Safety

Keep these files local to the target environment:

```text
config/windows/app.config.json
config/linux/app.env
.env
.env.*
*.key
*.pem
*.pfx
*.p12
```

The repository only includes example config files. Do not put real hostnames,
customer names, tokens, database URLs, certificates, or private keys into
committed examples.

## Target Preflight

Run target-specific preflight checks on the server before installing:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 -ConfigPath .\config\windows\app.config.json
```

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
```

If the configured port is already owned by the current service during an
intentional update, use the Windows `-AllowPortInUse` switch or Linux
`ALLOW_PORT_IN_USE="true"`.

## Deploy

Windows:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

Linux:

```bash
bash deploy.sh config/linux/app.env
```

Ansible:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/site.yml
```

## Post-Deploy Checks

Windows:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
Get-Service <AppName>
```

Linux:

```bash
systemctl status <app-name>
curl -fsS http://127.0.0.1:3000/health
```

Also confirm the public reverse proxy endpoint, recent logs, and reboot
behavior for new service installs.

For updates, confirm the backup directory contains any changed managed files
before deleting old release artifacts.
