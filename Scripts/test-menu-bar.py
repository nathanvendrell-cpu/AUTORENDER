#!/usr/bin/env python3
"""Pure formatter and mocked login-item checks. Never launches an application or registers a service."""
from pathlib import Path
import hashlib,json,os,signal,subprocess,tempfile,time,shutil
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('AUTORENDER_MENU_TEST_OUTPUT','/private/tmp/autoren-menu-evidence'));OUT.mkdir(parents=True,exist_ok=True)
runs=[];groups=[]
def rows(group):
 result=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,stat=,command='],text=True)
 return [line.strip() for line in result.splitlines() if len(line.split(None,4))==5 and int(line.split(None,4)[2])==group]
def run(args):
 p=subprocess.Popen([str(x) for x in args],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);groups.append(p.pid)
 try:
  out,err=p.communicate(timeout=180)
 finally:
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.communicate(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.communicate()
  if rows(p.pid):
   os.killpg(p.pid,signal.SIGTERM)
   for _ in range(30):
    if not rows(p.pid):break
    time.sleep(.1)
  assert not rows(p.pid), 'Task process group remains'
 runs.append({'argv':[str(x) for x in args],'exit':p.returncode,'stdout':out,'stderr':err})
 (OUT/'RUNS.json').write_text(json.dumps(runs,indent=2))
 assert p.returncode==0,err
 return out
signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(SystemExit(143)))
sources=sorted(p for folder in ['Application','Domain','Infrastructure'] for p in (ROOT/'Sources/RenduBar'/folder).glob('*.swift'))
sources += [ROOT/'Sources/RenduBar/App/LoginItemController.swift',ROOT/'Sources/RenduBar/App/LoginItemService.swift',ROOT/'Sources/RenduBar/App/MenuBarWidthPolicy.swift',ROOT/'Sources/RenduBar/App/StartupDiagnostic.swift',ROOT/'Scripts/MenuBarPresentationTests.swift']
typecheck=os.environ.get('AUTORENDER_MENU_TYPECHECK')=='1'
fullSources=sorted((ROOT/'Sources/RenduBar').rglob('*.swift'))
harnessSource=ROOT/'Scripts/UIHarness50.swift'
inputs=sorted(set(sources+([*fullSources,harnessSource] if typecheck else [])))
sourcePins={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
(OUT/'INPUT_PINS.json').write_text(json.dumps(sourcePins,indent=2))
protected=[Path.home()/'Applications/AUTORENDER.app/Contents/MacOS/RenduBar',ROOT/'Build/Products.noindex/AUTORENDER-0.8.0.app/Contents/MacOS/RenduBar']
before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
try:
 with tempfile.TemporaryDirectory(prefix='autoren-menu-') as temporary:
  copied={}
  for source in inputs:
   rel=source.relative_to(ROOT); target=Path(temporary)/'inputs'/rel; target.parent.mkdir(parents=True,exist_ok=True)
   shutil.copyfile(source,target)
   assert hashlib.sha256(target.read_bytes()).hexdigest()==sourcePins[str(rel)],'Source changed during snapshot'
   copied[source]=target
  assert all(hashlib.sha256((ROOT/k).read_bytes()).hexdigest()==v for k,v in sourcePins.items()),'Source changed during snapshot'
  frozen=[copied[p] for p in sources]
  for label,flags in [('normal',[]),('harness',['-D','AUTORENDER_UI_HARNESS'])]:
   exe=Path(temporary)/('check-bin-'+label)
   run(['/usr/bin/swiftc','-target','arm64-apple-macosx14.0','-parse-as-library',*flags,*frozen,'-o',exe])
   print(label+': '+run([exe]).strip(),flush=True)
  if typecheck:
   sparkle=ROOT/'Build/Dependencies.noindex/Sparkle-2.10.0'
   assert (sparkle/'Sparkle.framework').is_dir()
   for label,flags in [('normal',[]),('harness',['-D','AUTORENDER_UI_HARNESS'])]:
    graph=[copied[p] for p in fullSources]+([copied[harnessSource]] if label=='harness' else [])
    run(['/usr/bin/swiftc','-typecheck','-target','arm64-apple-macosx14.0',*flags,'-framework','AppKit','-framework','SwiftUI','-framework','ImageIO','-F',sparkle,'-framework','Sparkle',*graph])
    print(label+': App typecheck PASS',flush=True)
 (OUT/'CANONICAL_DELTA.json').write_text(json.dumps({'changedSinceFrozenSnapshot':[k for k,v in sourcePins.items() if hashlib.sha256((ROOT/k).read_bytes()).hexdigest()!=v]},indent=2))
 assert before=={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
finally:
 remaining=[line for group in groups for line in rows(group)]
 (OUT/'CLEANUP.json').write_text(json.dumps({'remainingTaskGroupsChildrenOrZ':remaining,'groups':groups,'intentionallyLeftRunning':[]},indent=2))
 assert not remaining
