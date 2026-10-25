#!/usr/bin/env python3
"""Provision pinned Sparkle; every reuse verifies framework bytes, modes and symlink targets."""
import ctypes,hashlib,json,os,stat,tarfile,tempfile,urllib.request
from pathlib import Path
root=Path(__file__).resolve().parents[1]
lock=json.loads((root/'Resources/Sparkle.lock.json').read_text())
cache=root/'Build/Dependencies.noindex'/('Sparkle-'+lock['version'])
def verify_framework(path):
    records={}
    if not path.is_dir() or path.is_symlink():raise SystemExit('Missing real framework directory')
    for item in [path,*sorted(path.rglob('*'))]:
        mode=stat.S_IMODE(item.lstat().st_mode)
        relative='.' if item==path else str(item.relative_to(path))
        if item.is_symlink():record=['symlink',mode,os.readlink(item)]
        elif item.is_dir():record=['directory',mode]
        elif item.is_file():record=['file',mode,hashlib.sha256(item.read_bytes()).hexdigest()]
        else:raise SystemExit('Unsupported framework node')
        records[relative]=record
    digest=hashlib.sha256(json.dumps(records,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    if digest!=lock['framework_inventory_sha256']:raise SystemExit('Framework inventory mismatch; preserve cache and investigate')
if cache.exists():
    verify_framework(cache/'Sparkle.framework')
else:
    cache.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='Sparkle-fetch-',dir=cache.parent) as temporary:
        staging=Path(temporary);archive=staging/'Sparkle.tar.xz'
        with urllib.request.urlopen(lock['url'],timeout=60) as response:archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=lock['sha256']:raise SystemExit('Official archive digest mismatch')
        extracted=staging/'distribution';extracted.mkdir()
        with tarfile.open(archive) as source:
            members=[m for m in source if m.name.removeprefix('./').split('/')[0] in ('Sparkle.framework','bin','LICENSE')]
            source.extractall(extracted,members=members,filter='tar')
        verify_framework(extracted/'Sparkle.framework')
        if cache.exists():raise SystemExit('Concurrent cache provisioning; preserve and retry')
        system=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
        system.renamex_np.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint]
        system.renamex_np.restype=ctypes.c_int
        if system.renamex_np(os.fsencode(extracted),os.fsencode(cache),4)!=0:
            raise OSError(ctypes.get_errno(),'Exclusive dependency cache rename failed')
for name in ('sign_update','generate_appcast'):
    tool=cache/'bin'/name
    if not tool.is_file() or tool.is_symlink() or hashlib.sha256(tool.read_bytes()).hexdigest()!=lock[name+'_sha256']:
        raise SystemExit('Official tool digest/type mismatch: '+name)
print(cache)
