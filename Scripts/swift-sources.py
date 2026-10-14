#!/usr/bin/env python3
"""List the complete Swift build input set in deterministic relative-path order."""
import os
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve(strict=True)
paths = []
for directory, dirs, files in os.walk(root, followlinks=False):
    dirs[:] = sorted(d for d in dirs if not Path(directory, d).is_symlink())
    for name in files:
        path = Path(directory, name)
        if path.suffix != ".swift":
            continue
        if path.is_symlink() or not path.is_file():
            raise SystemExit("Swift source must be a regular file: " + str(path))
        if "\n" in str(path) or "\r" in str(path):
            raise SystemExit("Newlines in Swift source paths are unsupported")
        paths.append(path)
if not paths:
    raise SystemExit("No Swift sources found")
for path in sorted(paths, key=lambda p: p.relative_to(root).as_posix()):
    print(path)
