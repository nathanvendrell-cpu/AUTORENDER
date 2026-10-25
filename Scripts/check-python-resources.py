#!/usr/bin/env python3
"""Import bundled helpers without bytecode or any collector invocation."""
import ast
import hashlib
import importlib
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve(strict=True)
modules = ("shadow_run_contract", "shadow_run_observer", "shadow_collector", "native_script_contract", "standard_render_observation", "render_library_transport")
templates = ("shadow_process_observer.ps1", "remote_library.ps1")
blender_modules = ("blender_render_relay",)
def inventory():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}
assert sys.dont_write_bytecode, "Run this check with Python -B"
assert not list(root.rglob("__pycache__")) and not list(root.rglob("*.pyc"))
before = inventory()
# Exact named resources only. Parse/read them without invoking the observer or PowerShell.
for name in modules + blender_modules:
    source = root / (name + ".py")
    assert source.is_file() and not source.is_symlink(), name
    ast.parse(source.read_text(encoding="utf-8-sig"), filename=source.name)
for name in templates:
    template = root / name
    assert template.is_file() and not template.is_symlink(), name
    assert template.read_text(encoding="utf-8-sig").strip(), "Empty observer template: " + name
sys.path.insert(0, str(root))
for name in modules:
    module = importlib.import_module(name)
    assert Path(module.__file__).resolve() == root / (name + ".py"), name
assert inventory() == before, "Bundled resources changed during imports"
assert not list(root.rglob("__pycache__")) and not list(root.rglob("*.pyc"))
print("Bundled Mac Python syntax/imports, Blender relay AST/UTF8 only (not imported), and named PowerShell template presence/UTF8 PASS; PowerShell not executed or syntax-validated; resource inventory unchanged; no bytecode")
