#!/usr/bin/env python3
"""Compile UI interfaces and verify simulated projection/selection/history boundaries."""
from pathlib import Path
import hashlib,json,os,signal,subprocess,tempfile
project=Path(__file__).resolve().parents[1]
sources=subprocess.check_output(['python3',str(project/'Scripts/swift-sources.py'),str(project/'Sources/RenduBar')],text=True).splitlines()
inputs=sources+[str(project/'Scripts/PresentationTests.swift'),str(project/'Scripts/UIHarness50.swift')]
def hashes():return {str(Path(x).relative_to(project)):hashlib.sha256(Path(x).read_bytes()).hexdigest() for x in inputs}
def run(command,timeout=60):
 process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try:
  out,err=process.communicate(timeout=timeout)
 finally:
  if process.poll() is None:
   os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=5)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
  rows=subprocess.check_output(['ps','-axo','pid=,pgid=,stat='],text=True).splitlines()
  remaining=[r for r in rows if len(r.split())==3 and r.split()[1]==str(process.pid)]
  if remaining:raise RuntimeError('Task process group has not exited: '+str(remaining))
 return {'exit':process.returncode,'pid':process.pid,'stdout':out,'stderr':err,'process_group_exited':True}
report={'scope':'No application launch/install/native UI; simulated metadata and isolated preferences only','before':hashes(),'checks':{}}
with tempfile.TemporaryDirectory(prefix='autorender-ui-check-',dir='/private/tmp') as tmp:
 common=['swiftc','-module-cache-path',tmp+'/cache','-framework','AppKit','-framework','SwiftUI','-framework','ImageIO']
 report['checks']['normal_typecheck']=run(common+['-typecheck']+sources)
 report['checks']['harness_typecheck']=run(common+['-typecheck','-D','AUTORENDER_UI_HARNESS']+sources+[str(project/'Scripts/UIHarness50.swift')])
 report['checks']['presentation_test_compile']=run(common+['-parse-as-library']+[x for x in sources if Path(x).name!='Main.swift']+[str(project/'Scripts/PresentationTests.swift'),'-o',tmp+'/tests'])
 if report['checks']['presentation_test_compile']['exit']==0:report['checks']['presentation_test_run']=run([tmp+'/tests'],timeout=20)
 report['after']=hashes()
 after_sources=subprocess.check_output(['python3',str(project/'Scripts/swift-sources.py'),str(project/'Sources/RenduBar')],text=True).splitlines()
 report['inputs_stable']=report['before']==report['after'] and sources==after_sources
 report['status']='PASS' if report['inputs_stable'] and all(c['exit']==0 for c in report['checks'].values()) else 'FAILED_OR_SOURCE_CHANGED'
output=project/'Evidence/AUTORENDER-MACOS-060-UI-CHECKS-20261012.json'
output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'status':report['status'],'inputs_stable':report['inputs_stable'],'checks':report['checks'],'report':str(output)}))
raise SystemExit(0 if report['status']=='PASS' else 1)
