#!/usr/bin/env python3
"""Very small secret-pattern guard for examples. Not a replacement for a real secret scanner."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[2]
patterns = [
    re.compile(r"(?i)(password|secret|token|apikey|api_key)\s*[:=]\s*['\"]?[A-Za-z0-9_\-]{12,}"),
    re.compile(r"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"),
]
ignore_dirs = {".git", ".tmp", "node_modules", ".next", "dist", "build"}
failed = False
for path in root.rglob("*"):
    if path.is_dir() or any(part in ignore_dirs for part in path.parts):
        continue
    if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".zip", ".exe"}:
        continue
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        continue
    for pat in patterns:
        if pat.search(text):
            print(f"Potential secret pattern in {path.relative_to(root)}")
            failed = True
if failed:
    sys.exit(1)
print("No obvious secrets found.")
