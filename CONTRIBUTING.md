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
