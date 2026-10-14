#!/usr/bin/env python3
"""Run catalogue persistence fixtures using only a temporary instrumented source copy.

Usage: python3 -B Tests/check_catalog_persistence.py
No application, renderer, network, real configuration or catalogue is opened.
"""
from pathlib import Path
import hashlib,json,os,shutil,signal,subprocess,tempfile

project=Path(__file__).resolve().parents[1]
service_name='Sources/RenduBar/Infrastructure/RenderCatalogService.swift'
fixture=project/'Tests/CatalogPersistenceFixTests.swift'
tracked=[]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def source_pins():
 return {str(p.relative_to(project)):digest(p) for p in sorted((project/'Sources').rglob('*')) if p.is_file()}
def run(command,timeout=60):
 process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
 tracked.append(process.pid)
 try:
  stdout,stderr=process.communicate(timeout=timeout)
 finally:
  if process.poll() is None:
   os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=3)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL)
  process.wait()
 if process.returncode:
  raise RuntimeError('Fixture command failed with exit '+str(process.returncode)+'\n'+stderr.decode(errors='replace'))
 return stdout

def main():
 before=source_pins();fixture_pin=digest(fixture)
 with tempfile.TemporaryDirectory(prefix='autoren-public-persistence-') as temporary:
  work=Path(temporary);shutil.copytree(project/'Sources',work/'Sources')
  service=work/service_name;original=service.read_text()
  boundary='try data.write(to: root.appendingPathComponent("jobs.json"), options: .atomic);'
  if original.count(boundary)!=1:raise RuntimeError('Expected exactly one atomic catalogue write boundary')
  injected='try FixturePersistenceHook.check(); '
  instrumented=original.replace(boundary,injected+boundary)
  if instrumented.replace(injected,'',1)!=original:raise RuntimeError('Unexpected fixture instrumentation delta')
  service.write_text(instrumented)
  test=work/'CatalogPersistenceFixTests.swift';shutil.copy2(fixture,test)
  sources=sorted(str(p) for p in (work/'Sources/RenduBar').rglob('*.swift') if p.name!='Main.swift')
  executable=work/'tests';storage=work/'neutral-storage';storage.mkdir()
  run(['swiftc','-parse-as-library','-module-cache-path',str(work/'cache'),*sources,str(test),'-o',str(executable)])
  result=json.loads(run([str(executable),str(storage)]))
 if source_pins()!=before or digest(fixture)!=fixture_pin:raise RuntimeError('Public sources or fixture changed')
 rows=subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,check=True,text=True).stdout.splitlines()
 remaining=[r for r in rows if len(r.split())==3 and int(r.split()[1]) in tracked]
 if remaining:raise RuntimeError('Task-owned process group did not exit')
 result.update({'public_sources_unchanged':True,'fixture_unchanged':True,'temporary_removed':not work.exists(),'process_groups_exited':True,'instrumentation_copy_only':True,'native_runtime_cause':'UNKNOWN; fixtures do not attribute the initial runtime error'})
 print(json.dumps(result,sort_keys=True))
 if result.get('result')!='PASS' or result.get('assertions')!=23:raise RuntimeError('Incomplete fixture result')

if __name__=='__main__':main()
