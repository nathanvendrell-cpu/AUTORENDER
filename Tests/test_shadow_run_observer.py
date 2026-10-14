import sys,json,datetime,copy,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources/RenduBar/Infrastructure'))
from shadow_run_contract import contract,decode_source,ContractError
from shadow_run_observer import validate_configs,decode,auto_configs,observe
NOW=datetime.datetime.now(datetime.timezone.utc).isoformat()
LAUNCHER="""$D = Split-Path -Parent $MyInvocation.MyCommand.Path; $V = Split-Path -Parent $D
$S = Join-Path $V 'scene.py'; $PO = Join-Path $V 'grade.py'
$F = Join-Path $D 'outputs'; $OUT = Join-Path $F 'frames'; $POST = Join-Path $F 'graded'; $J = Join-Path $F 'journal.txt'
$R = @{ A = @(1, 3); B = @(4, 6) }
$a=@('-b','-P',$S,'--','--plan',$n,'--anim',$OUT)
& $BL -b -P $PO -- dossier $tmp $POST
$p=('{0}_{1:D4}.png' -f $n,$_)
"""
PATH=r'C:\fixture\run\start.ps1';C=contract(PATH,LAUNCHER)
CONFIG={'id':'fixture','launcherPath':PATH,'scriptPath':C['paths']['S'],'postScriptPath':C['paths']['PO'],'outputRoot':C['paths']['F'],'rawRoot':C['paths']['OUT'],'postRoot':C['paths']['POST'],'plans':C['plans'],'expectedScriptSHA256':'a'*64}
def source():
 return {'sourceID':'fixture','observedAt':NOW,'outputBirth':NOW,'launcher':{'path':PATH,'sha256':'b'*64,'content':LAUNCHER},'sources':[{'path':C['paths']['S'],'sha256':'a'*64},{'path':C['paths']['PO'],'sha256':'c'*64}],'stages':{role:{'root':C['paths']['OUT' if role=='raw' else 'POST'],'files':[{'name':name,'bytes':10,'modified':NOW} for name in C['expected'][:(5 if role=='raw' else 3)]]} for role in ['raw','post']},'logs':{'B.log.err':['Out of memory','FILE FIN']},'logTimes':{'B.log.err':NOW}}
def packet():return {'ok':True,'observedAt':NOW,'partial':False,'processes':[],'runs':[source()],'autoLaunchers':[]}
def automatic_packet(second=False):
 p=packet();p['autoLaunchers']=[copy.deepcopy(p['runs'][0]['launcher'])];a=auto_configs(p)[0]
 p['runs'][0]['sourceID']=a['id'];p['processes']=[{'name':'blender.exe','ownerVerified':True,'pid':10,'birth':NOW,'argv':f'blender.exe -b -P "{C["paths"]["S"]}" -- --plan A --anim "{C["paths"]["OUT"]}"'}]
 return p,a
class Tests(unittest.TestCase):
 def test_auto_source_observed_followup(self):
  p,a=automatic_packet();first=copy.deepcopy(p);first['runs']=[];replies=iter([first,p]);calls=[]
  def fetch(argv,seconds,input_bytes=None):calls.append(seconds);return json.dumps(next(replies)).encode()
  r=observe([],lambda:('fixture','fixture',Path('/fixture-key')),lambda key:[],fetch)
  self.assertEqual(len(calls),2);self.assertEqual(len(r['runs']),1);self.assertEqual(r['runs'][0]['activity'],'running');self.assertEqual(r['automaticSources'][0]['source']['id'],a['id']);self.assertEqual(r['automaticSources'][0]['claims'],r['runs'][0]['claims'])
 def test_auto_requires_observed_launcher_and_worker(self):
  p,a=automatic_packet();p['processes']=[];self.assertEqual(decode(p,[a],[])['runs'],[])
  p,a=automatic_packet();p['autoLaunchers']=[];self.assertEqual(decode(p,[a],[])['automaticSources'],[])
  p,a=automatic_packet();p['autoLaunchers'][0]['sha256']='d'*64;self.assertEqual(decode(p,[a],[])['runs'],[])
 def test_auto_cannot_override_declared_scope(self):
  p,a=automatic_packet();bad=copy.deepcopy(a);bad['rawRoot']=r'C:\foreign\raw'
  with self.assertRaises(ContractError):decode(p,[bad],[a['id']])

 def test_positive_worker_with_partial_coverage(self):
  for command,phase in [(f'blender.exe -b -P "{C["paths"]["S"]}" -- --plan A --anim "{C["paths"]["OUT"]}"','raw'),(f'blender.exe -b -P "{C["paths"]["PO"]}" -- dossier "{C["paths"]["F"]}\\post_A" "{C["paths"]["POST"]}"','post')]:
   p=packet();p['partial']=True;p['processes']=[{'name':'blender.exe','ownerVerified':True,'pid':10,'birth':NOW,'argv':command}]
   r=decode(p,[CONFIG])['runs'][0];self.assertFalse(r['processCoverage']);self.assertEqual(r['activity'],'running');self.assertEqual(r['provenance'],'process_observed');self.assertEqual(r['claims'][0]['phase'],phase)
  p['processes']=[];self.assertEqual(decode(p,[CONFIG])['runs'][0]['activity'],'unknown')

 def test_impostor_engine_rejected(self):
  for name in ['powershell.exe','python.exe','ffmpeg.exe','']:
   for command in [f'blender.exe -b -P "{C["paths"]["S"]}" -- --plan A --anim "{C["paths"]["OUT"]}"',f'blender.exe -b -P "{C["paths"]["PO"]}" -- dossier "{C["paths"]["F"]}\\post_A" "{C["paths"]["POST"]}"']:
    p=packet();p['processes']=[{'name':name,'pid':10,'birth':NOW,'argv':command}]
    self.assertEqual(decode(p,[CONFIG])['runs'][0]['claims'],[])

 def test_distinct_declared_and_error(self):
  r=decode(packet(),[CONFIG])['runs'][0];self.assertEqual((r['rawCount'],r['postCount'],r['total']),(5,3,6));self.assertEqual(r['activity'],'resumeRequired');self.assertEqual(r['provenance'],'source_declared');self.assertEqual(r['missingRaw'],['B_0006.png']);self.assertEqual(r['planCounts']['B']['post'],0)
 def test_no_finish_from_marker(self):
  p=packet();p['runs'][0]['logs']={'journal.txt':['FILE FIN']};r=decode(p,[CONFIG])['runs'][0];self.assertEqual(r['activity'],'unknown');self.assertTrue(r['missingRaw'])
 def test_exact_process_claim_and_reuse(self):
  p=packet();p['processes']=[{'name':'blender.exe','ownerVerified':True,'pid':10,'birth':NOW,'argv':f'blender.exe -b -P "{C["paths"]["S"]}" -- --plan A --anim "{C["paths"]["OUT"]}"'}];r=decode(p,[CONFIG])['runs'][0];self.assertEqual(r['activity'],'running');self.assertEqual(r['provenance'],'process_observed');p['processes'][0]['birth']='2020-01-01T00:00:00Z';self.assertEqual(r['id'],decode(p,[CONFIG])['runs'][0]['id']);c=copy.deepcopy(CONFIG);c['runToken']='second';self.assertNotEqual(r['id'],decode(p,[c])['runs'][0]['id'])
 def test_worker_succession_one_scope_job(self):
  p=packet();ids=[]
  for pid,birth,phase,frame in [(10,NOW,'raw',257),(11,'2020-01-01T00:00:00Z','raw',258),(12,NOW,'post',None),(0,NOW,'none',None)]:
   if phase=='raw':command=f'blender -P "{C["paths"]["S"]}" --plan A --anim "{C["paths"]["OUT"]}" --frame {frame}'
   elif phase=='post':command=f'blender -P "{C["paths"]["PO"]}" -- dossier "{C["paths"]["F"]}\\post_B" "{C["paths"]["POST"]}"'
   else:command=''
   p['processes']=[] if pid==0 else [{'name':'blender.exe','ownerVerified':True,'pid':pid,'birth':birth,'argv':command}]
   r=decode(p,[CONFIG])['runs'][0];ids.append(r['id']);self.assertEqual((r['rawCount'],r['postCount']),(5,3))
  self.assertEqual(len(set(ids)),1)
 def test_wrong_root_partial(self):
  p=packet();p['processes']=[{'name':'blender.exe','ownerVerified':True,'pid':10,'birth':NOW,'argv':f'blender -P "{C["paths"]["S"]}" --plan A --anim "C:\\elsewhere\\frames"'}];self.assertNotEqual(decode(p,[CONFIG])['runs'][0]['activity'],'running');p['partial']=True;self.assertEqual(decode(p,[CONFIG])['runs'][0]['claims'],[])
 def test_bad_truncated_and_changed_hash(self):
  p=packet();p['runs']=[]
  with self.assertRaises(ContractError):decode(p,[CONFIG])
  p=packet();p['runs'][0]['sources'][0]['sha256']='d'*64
  with self.assertRaises(ContractError):decode(p,[CONFIG])
 def test_duplicate_and_reparse(self):
  p=packet();p['runs'][0]['stages']['raw']['files'].append(p['runs'][0]['stages']['raw']['files'][0])
  with self.assertRaises(ContractError):decode(p,[CONFIG])
  p=packet();p['runs'][0]['stages']['raw']['files'][0]['reparse']=True
  with self.assertRaises(ContractError):decode(p,[CONFIG])
 def test_auto_from_actual_launcher_not_name(self):
  r=auto_configs({'autoLaunchers':[{'path':PATH,'content':LAUNCHER}]});self.assertEqual(len(r),1);self.assertEqual(r[0]['plans'],C['plans']);self.assertNotIn('v004',json.dumps(r))
 def test_terminal_requires_both_stages_and_full_coverage(self):
  p=packet()
  for role in ['raw','post']:p['runs'][0]['stages'][role]['files']=[{'name':n,'bytes':10,'modified':NOW} for n in C['expected']]
  p['processes']=[{'name':'blender.exe','ownerVerified':True,'pid':42,'birth':NOW,'argv':'blender -P "C:\\other\\script.py" --anim "C:\\other\\frames"'}]
  self.assertEqual(decode(p,[CONFIG])['runs'][0]['activity'],'countsReached')
  p['partial']=True;self.assertEqual(decode(p,[CONFIG])['runs'][0]['activity'],'unknown')
  p['partial']=False;p['runs'][0]['stages']['post']['files']=[]
  self.assertNotEqual(decode(p,[CONFIG])['runs'][0]['activity'],'countsReached')
 def test_limits_and_same_stage(self):
  c=copy.deepcopy(CONFIG);c['postRoot']=c['rawRoot']
  with self.assertRaises(ContractError):validate_configs([c])
  with self.assertRaises(ContractError):contract(PATH,LAUNCHER+'x'*32768)
 def test_plan_changed_same_total_rejected(self):
  p=packet();c=copy.deepcopy(CONFIG);c['plans']={'A':[0,2],'B':[3,5]}
  with self.assertRaises(ContractError):decode(p,[c])
if __name__=='__main__':unittest.main()
