import sys,io,json,unittest,importlib.util,contextlib,base64,gzip,hashlib,subprocess,tempfile,os,time
from pathlib import Path
from unittest.mock import patch
HERE=Path(__file__).resolve().parent;BASE=HERE.parent;sys.path.insert(0,str(BASE/'Sources/RenduBar/Infrastructure'))
import shadow_collector as collector
import shadow_run_observer as observer
class IgnoreReceipt:
 def write_text(self,*args,**kwargs):pass
def receipt_path(name):
 directory=os.environ.get('AUTORENDER_TEST_RECEIPTS')
 return Path(directory)/name if directory else IgnoreReceipt()
class FakeProcess:
 def __init__(self,code=255,error=b'',timeout=False):
  self.returncode=None if timeout else code;self.error=error;self.timeout=timeout;self.stdout=io.BytesIO();self.stderr=io.BytesIO();self.input=None
 def communicate(self,input=None,timeout=None):
  self.input=input
  if self.timeout:raise subprocess.TimeoutExpired('fixture-no-network',timeout)
  return b'fixture-output',self.error
 def poll(self):return self.returncode
class Tests(unittest.TestCase):
 def test_ssh255_and_privacy(self):
  error=b'Permission denied for fixture-user@192.0.2.123 with key /private/fixture-secret and C:\\CLIENT\\SECRET'
  fake=FakeProcess(255,error)
  with patch.object(collector.subprocess,'Popen',return_value=fake):
   with self.assertRaises(collector.CollectorCommandError) as failure:collector.run(['ssh','fixture'],12)
  result=collector.observation_failure(failure.exception);self.assertEqual(result['diagnostic'],{'phase':'ssh_transport','reason':'authentication_failed','exitCode':255,'timedOut':False,'elapsedSeconds':result['diagnostic']['elapsedSeconds']});self.assertGreaterEqual(result['diagnostic']['elapsedSeconds'],0)
  blob=json.dumps(result)
  for secret in ['fixture-user','192.0.2.123','fixture-secret','CLIENT','SECRET']:self.assertNotIn(secret,blob)
 def test_remote_powershell_nonzero(self):
  result=collector.observation_failure(collector.CollectorCommandError('ssh',1,b'ParserError: unexpected token at C:\\private\\client.ps1'))
  self.assertEqual(result['diagnostic']['phase'],'remote_powershell_parse');self.assertEqual(result['diagnostic']['exitCode'],1);self.assertNotIn('client.ps1',json.dumps(result))
 def test_unknown_nonzero_retains_status_without_fabrication(self):
  result=collector.observation_failure(collector.CollectorCommandError('ssh',7,b'private-unrecognized-text'))
  self.assertEqual(result['diagnostic']['phase'],'remote_command');self.assertEqual(result['diagnostic']['reason'],'nonzero_exit');self.assertEqual(result['diagnostic']['exitCode'],7);self.assertNotIn('private-unrecognized-text',json.dumps(result))
 def test_timeout_cleanup_and_privacy(self):
  fake=FakeProcess(timeout=True)
  def stop():fake.returncode=-15
  with patch.object(collector.subprocess,'Popen',return_value=fake),patch.object(collector,'stop_active',side_effect=stop) as cleanup:
   with self.assertRaises(collector.CollectorCommandError) as failure:collector.run(['ssh','private-host'],12)
   self.assertGreater(cleanup.call_count,0)
  result=collector.observation_failure(failure.exception);self.assertTrue(result['diagnostic']['timedOut']);self.assertEqual(result['diagnostic']['phase'],'ssh_timeout');self.assertIsNone(collector.ACTIVE)
 def test_local_configuration(self):
  result=collector.observation_failure(RuntimeError('Shadow SSH identity unavailable'));self.assertEqual(result['diagnostic']['phase'],'local_connection');self.assertEqual(result['diagnostic']['reason'],'identity_key_unavailable')
 def test_contract_and_json_are_separate(self):
  from shadow_run_contract import ContractError
  self.assertEqual(collector.observation_failure(ContractError('private-path'))['diagnostic']['phase'],'observation_contract')
  try:json.loads('{broken')
  except json.JSONDecodeError as e:self.assertEqual(collector.observation_failure(e)['diagnostic']['phase'],'snapshot_json')
 def test_main_observe_emits_diagnostic_without_network(self):
  failure=collector.CollectorCommandError('ssh',255,b'Could not resolve hostname private-host')
  with patch.object(observer,'observe',side_effect=failure),patch.object(sys,'argv',['fixture','observe','--roots-json','[]','--sources-json','[]']),contextlib.redirect_stdout(io.StringIO()) as out:
   exit_code=collector.main()
  result=json.loads(out.getvalue());self.assertEqual(exit_code,1);self.assertEqual(result['diagnostic']['reason'],'hostname_resolution');self.assertNotIn('private-host',out.getvalue())
 def test_stdin_forwarding_and_success_unchanged(self):
  fake=FakeProcess(0)
  with patch.object(collector.subprocess,'Popen',return_value=fake) as spawn:
   result=collector.run(['ssh','fixture'],12,input_bytes=b'fixture-stdin')
   self.assertEqual(spawn.call_args.kwargs['stdin'],subprocess.PIPE)
  self.assertEqual(fake.input,b'fixture-stdin');self.assertEqual(result,b'fixture-output')
 def test_neutral_payload_roundtrip_and_command_limit(self):
  from test_shadow_run_observer import CONFIG
  sources=[CONFIG];command,payload=observer.stdin_transport(sources)
  restored=gzip.decompress(base64.b64decode(payload));self.assertEqual(restored,observer.ps_script(sources).encode('utf-8'));self.assertLess(len(command),8191)
  self.assertNotIn(sources[0]['launcherPath'],command)
  receipt_path('transport-size-receipt.json').write_text(json.dumps({'localOnly':True,'networkRequests':0,'oldRemoteCommandCharacters':14198,'candidateRemoteCommandCharacters':len(command),'stdinPayloadBytes':len(payload),'scriptUTF8Bytes':len(restored),'gzipRoundtripExact':True,'scriptSHA256':hashlib.sha256(restored).hexdigest(),'actualRemoteDefaultShell':'NOT_OBSERVED','actualOriginalFailureCause':'NOT_RETAINED'},indent=2)+'\n')
 def test_cancelled_is_separate_and_sanitized(self):
  result=collector.observation_failure(KeyboardInterrupt('private-command-secret'),elapsed_seconds=.1)
  self.assertEqual(result['diagnostic']['phase'],'cancelled');self.assertEqual(result['diagnostic']['elapsedSeconds'],.1);self.assertNotIn('private-command-secret',json.dumps(result))
 def test_actual_local_fake_ssh_stdin_pipe_and_reaping(self):
  with tempfile.TemporaryDirectory(prefix='autoren-local-fake-ssh-') as td:
   root=Path(td);fake=root/'ssh';received=root/'received.json'
   fake.write_text("#!"+sys.executable+" -B\nimport sys,base64,gzip,json,os\nfrom pathlib import Path\npayload=sys.stdin.buffer.read();script=gzip.decompress(base64.b64decode(payload));Path("+repr(str(received))+").write_text(json.dumps({'pid':os.getpid(),'bytes':len(script),'sha256':__import__('hashlib').sha256(script).hexdigest(),'argvLength':len(sys.argv[-1])}));print(json.dumps({'ok':True}))\n")
   fake.chmod(0o700);command,payload=observer.stdin_transport([])
   result=collector.run([str(fake),command],2,input_bytes=payload);record=json.loads(received.read_text())
   self.assertEqual(json.loads(result),{'ok':True});self.assertEqual(record['sha256'],hashlib.sha256(observer.ps_script([]).encode()).hexdigest());self.assertLess(record['argvLength'],8191)
   state=subprocess.run(['/bin/ps','-o','pid=,stat=','-p',str(record['pid'])],capture_output=True,text=True);self.assertEqual(state.stdout.strip(),'');self.assertIsNone(collector.ACTIVE)
   receipt_path('actual-local-fake-ssh-receipt.json').write_text(json.dumps({'networkRequests':0,'helperPID':record['pid'],'stdinRoundtripExact':True,'argvBelow8191':True,'helperExitedReaped':True},indent=2)+'\n')
 def test_actual_local_timeout_reaps_stubborn_child(self):
  with tempfile.TemporaryDirectory(prefix='autoren-local-timeout-') as td:
   root=Path(td);fake=root/'ssh';pidfile=root/'pid'
   fake.write_text("#!"+sys.executable+" -B\nimport signal,time,os\nfrom pathlib import Path\nsignal.signal(signal.SIGTERM,signal.SIG_IGN);Path("+repr(str(pidfile))+").write_text(str(os.getpid()));time.sleep(10)\n");fake.chmod(0o700)
   real_spawn=collector.subprocess.Popen
   def ready_spawn(*args,**kwargs):
    process=real_spawn(*args,**kwargs);deadline=time.monotonic()+5
    while not pidfile.exists() and process.poll() is None and time.monotonic()<deadline:time.sleep(.01)
    if not pidfile.exists():
     if process.poll() is None:process.kill()
     process.wait();raise RuntimeError('local fixture failed its readiness handshake')
    return process
   with patch.object(collector.subprocess,'Popen',side_effect=ready_spawn):
    with self.assertRaises(collector.CollectorCommandError) as failure:collector.run([str(fake)],.2,input_bytes=b'fixture')
   pid=int(pidfile.read_text());state=subprocess.run(['/bin/ps','-o','pid=,stat=','-p',str(pid)],capture_output=True,text=True)
   self.assertEqual(state.stdout.strip(),'');self.assertIsNone(collector.ACTIVE);self.assertTrue(failure.exception.diagnostic['timedOut'])
   receipt_path('actual-local-timeout-receipt.json').write_text(json.dumps({'networkRequests':0,'helperPID':pid,'timedOut':True,'forcedKillTaskOwnedOnly':True,'helperExitedReaped':True},indent=2)+'\n')
 def test_script_limit(self):
  with patch.object(observer,'ps_script',return_value='x'*131073):
   from shadow_run_contract import ContractError
   with self.assertRaises(ContractError):observer.stdin_transport([])
if __name__=='__main__':unittest.main()
