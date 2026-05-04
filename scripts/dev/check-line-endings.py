#!/usr/bin/env python3
"""Fail when shell/Linux deployment files contain CRLF line endings."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
CHECKED_GLOBS = [
    "deploy.sh",
    "scripts/dev/*.sh",
    "scripts/linux/*.sh",
    "config/linux/*.env.example",
    "templates/linux/*",
    "ansible/roles/linux_node_service/templates/*",
]

failed = []
for pattern in CHECKED_GLOBS:
    for path in ROOT.glob(pattern):
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\r\n" in data:
            failed.append(path.relative_to(ROOT))

if failed:
    print("CRLF line endings found in LF-only files:")
    for path in failed:
        print(f"  {path}")
    sys.exit(1)

print("Line endings OK")
