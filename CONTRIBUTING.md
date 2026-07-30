# Contributing

Thank you for contributing.

## Rules

- Do not add private data, customer names, internal IP addresses, credentials, or screenshots with sensitive information.
- Keep examples generic and variable-driven.
- Prefer idempotent scripts.
- Keep Windows and Linux behavior symmetrical where possible.
- Add comments for deployment-impacting logic.

## Development Checklist

Before opening a pull request:

```bash
bash scripts/dev/lint-shell-basic.sh
python3 scripts/dev/check-no-secrets.py
```

Preferred full check:

```powershell
.\scripts\dev\Test-Repository.ps1
.\scripts\dev\Test-DocsConsistency.ps1
.\scripts\dev\Test-GitHubActionsSecurity.ps1
.\scripts\dev\Test-ReleasePackage.ps1
```

When updating a GitHub Action, keep its `uses:` reference pinned to the
reviewed 40-character commit SHA and update the adjacent major-version
comment. Update the allowlist in `Test-GitHubActionsSecurity.ps1` in the same
change; never merge a Dependabot action update without reviewing the upstream
release and commit.

For release handoff, build a sanitized package:

```powershell
.\scripts\dev\New-ReleasePackage.ps1 -Version dev
```
