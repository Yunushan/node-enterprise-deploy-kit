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
- obvious committed secret patterns
- `git diff --check` whitespace problems

On Windows, install Git Bash or another `bash` executable for the shell syntax
step. If you are only checking Windows scripts on a restricted machine, use:

```powershell
.\scripts\dev\Test-Repository.ps1 -SkipShellSyntax
```

Ansible playbook syntax is checked automatically when `ansible-playbook` is
available. If Ansible is not installed on the validation machine, that optional
check is skipped.

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
