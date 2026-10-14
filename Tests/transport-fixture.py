import sys,time,json,fcntl,os
from pathlib import Path
root=Path(sys.argv[1]);mode=sys.argv[2]
with (root/'lock').open('a') as f:
 try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:sys.exit(12)
 (root/mode).write_text(str(os.getpid()))
 if mode=='imports':
  assert sys.dont_write_bytecode
  import shadow_collector,shadow_run_observer,shadow_run_contract
  print(json.dumps({'ok':True,'bytecodeDisabled':sys.dont_write_bytecode}))
 elif mode=='large':print('x'*(2*1024*1024+1))
 else:
  time.sleep(.3);print(json.dumps({'ok':True}))
