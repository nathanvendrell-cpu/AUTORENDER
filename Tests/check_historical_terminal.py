#!/usr/bin/env python3
"""Run neutral historical-terminal fixtures without application/network/runtime data.

Usage: python3 -B Tests/check_historical_terminal.py
"""
from pathlib import Path
import hashlib,json,os,shutil,signal,subprocess,tempfile
project=Path(__file__).resolve().parents[1]
fixture=project/'Tests/HistoricalTerminalTests.swift'
neutral=project/'Tests/Fixtures/historical-terminal.json'
tracked=[]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def pins():
 return {str(p.relative_to(project)):digest(p) for p in sorted((project/'Sources').rglob('*')) if p.is_file()}
def run(command):
 child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True);tracked.append(child.pid)
 try:out,err=child.communicate(timeout=60)
 finally:
  if child.poll() is None:
   os.killpg(child.pid,signal.SIGTERM)
   try:child.wait(timeout=3)
   except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL)
  child.wait()
 if child.returncode:raise RuntimeError('Historical fixture failed with exit '+str(child.returncode)+'\n'+err.decode(errors='replace'))
 return out
def main():
 before=pins();fixture_pin=digest(fixture);neutral_pin=digest(neutral)
 with tempfile.TemporaryDirectory(prefix='autoren-public-historical-') as temporary:
  work=Path(temporary);shutil.copytree(project/'Sources',work/'Sources')
  test=work/'HistoricalTerminalTests.swift';data=work/'terminal.json';shutil.copy2(fixture,test);shutil.copy2(neutral,data)
  storage=work/'neutral-storage';storage.mkdir();executable=work/'tests'
  sources=sorted(str(p) for p in (work/'Sources/RenduBar').rglob('*.swift') if p.name!='Main.swift')
  run(['swiftc','-parse-as-library','-module-cache-path',str(work/'cache'),*sources,str(test),'-o',str(executable)])
  result=json.loads(run([str(executable),str(data),str(storage)]))
 if pins()!=before or digest(fixture)!=fixture_pin or digest(neutral)!=neutral_pin:raise RuntimeError('Public input changed')
 rows=subprocess.run(['ps','-axo','pid=,pgid=,stat='],capture_output=True,check=True,text=True).stdout.splitlines()
 if any(len(r.split())==3 and int(r.split()[1]) in tracked for r in rows):raise RuntimeError('Historical task process group still present')
 result.update({'public_sources_unchanged':True,'fixtures_unchanged':True,'temporary_removed':not work.exists(),'process_groups_exited':True,'runtime_proof':False})
 print(json.dumps(result,sort_keys=True))
 if result.get('result')!='PASS' or result.get('assertions')!=23:raise RuntimeError('Incomplete historical fixture result')
if __name__=='__main__':main()
