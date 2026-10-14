#!/usr/bin/env python3
"""Import bundled helpers without bytecode or any collector invocation."""
import hashlib
import importlib
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve(strict=True)
modules = ("shadow_run_contract", "shadow_run_observer", "shadow_collector", "native_script_contract")
def inventory():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}
assert sys.dont_write_bytecode, "Run this check with Python -B"
assert not list(root.rglob("__pycache__")) and not list(root.rglob("*.pyc"))
before = inventory()
sys.path.insert(0, str(root))
for name in modules:
    module = importlib.import_module(name)
    assert Path(module.__file__).resolve() == root / (name + ".py"), name
assert inventory() == before, "Bundled resources changed during imports"
assert not list(root.rglob("__pycache__")) and not list(root.rglob("*.pyc"))
print("Bundled Python imports PASS; resource inventory unchanged; no bytecode")
