"""Pure bounded validation of an observed, supported PowerShell launcher contract."""
import hashlib,json,ntpath,re,datetime
MAX_LAUNCHER=32768;MAX_FRAMES=20000;MAX_PROCESSES=24
class ContractError(ValueError):pass
def digest(value):return hashlib.sha256(value.encode()).hexdigest()
def normalized(path):
 if not isinstance(path,str) or len(path)>390 or not re.match(r'^[A-Za-z]:[\\/]',path) or any(c in path for c in "\r\n\0'\"`$;") or '..' in path.replace('\\','/').split('/'):raise ContractError('path')
 return ntpath.normpath(path).replace('\\','/').lower()
def inside(path,root):return normalized(path).startswith(normalized(root).rstrip('/')+'/')
def contract(launcher,body):
 normalized(launcher)
 if len(body.encode())>MAX_LAUNCHER:raise ContractError('launcher limit')
 # Supported schema is inferred from the actual launcher, never executed.
 if '$MyInvocation.MyCommand.Path' not in body:raise ContractError('unsupported launcher')
 values={'D':ntpath.dirname(launcher),'V':ntpath.dirname(ntpath.dirname(launcher))}
 for m in re.finditer(r"\$(\w+)\s*=\s*Join-Path\s+\$(\w+)\s+'([^']+)'",body):
  key,parent,leaf=m.groups()
  if parent in values and not re.search(r'[/\\]',leaf):values[key]=ntpath.join(values[parent],leaf)
 required=['S','PO','F','OUT','POST','J']
 if any(k not in values for k in required):raise ContractError('missing paths')
 if not all(inside(values[k],values['F']) for k in ['OUT','POST','J']):raise ContractError('stage scope')
 if normalized(values['OUT'])==normalized(values['POST']):raise ContractError('merged stages')
 if not re.search(r"'--anim'\s*,.{0,16}\$OUT",body):raise ContractError('raw invocation')
 if not re.search(r'\$PO.+?dossier.+?\$POST',body,re.S):raise ContractError('post invocation')
 if "'{0}_{1:D4}.png'" not in body:raise ContractError('frame pattern')
 match=re.search(r'\$R\s*=\s*@\{([^}]+)\}',body)
 if not match:raise ContractError('missing plan')
 plans={m.group(1):(int(m.group(2)),int(m.group(3))) for m in re.finditer(r'([A-Za-z][A-Za-z0-9_-]{0,15})\s*=\s*@\(\s*(\d+)\s*,\s*(\d+)\s*\)',match.group(1))}
 if not plans or len(plans)>32:raise ContractError('plan limit')
 occupied=set();expected=[]
 for plan,(start,end) in sorted(plans.items()):
  if start<0 or end<start or end-start+1>MAX_FRAMES:raise ContractError('range')
  if occupied.intersection(range(start,end+1)):raise ContractError('overlap')
  occupied.update(range(start,end+1));expected.extend(f'{plan}_{n:04d}.png' for n in range(start,end+1))
 if len(expected)>MAX_FRAMES:raise ContractError('frame limit')
 return {'paths':values,'plans':{k:list(v) for k,v in plans.items()},'expected':expected,'total':len(expected)}
def argv_tokens(command):return re.findall(r'"([^"\r\n]*)"|([^\s"\r\n]+)',command or '')
def tokens(command):return [a or b for a,b in argv_tokens(command)]
def take(tokens,key):
 try:return tokens[tokens.index(key)+1]
 except (ValueError,IndexError):return None
def decode_source(source,config,processes,process_coverage,now):
 launcher=source.get('launcher',{});c=contract(launcher.get('path',''),launcher.get('content',''))
 if normalized(config['launcherPath'])!=normalized(launcher['path']):raise ContractError('launcher mismatch')
 hashes={normalized(x['path']):x['sha256'].lower() for x in source.get('sources',[])}
 scriptHash=hashes.get(normalized(c['paths']['S']));postHash=hashes.get(normalized(c['paths']['PO']))
 if not scriptHash or not postHash or not re.fullmatch('[0-9a-f]{64}',scriptHash+'' ):raise ContractError('script hash')
 expected=config.get('expectedScriptSHA256')
 if expected and scriptHash!=expected.lower():raise ContractError('script changed')
 present={};missing={};frames=[];planCounts={p:{} for p in c['plans']}
 for role in ['raw','post']:
  stage=source['stages'][role]
  path=c['paths']['OUT' if role=='raw' else 'POST']
  if normalized(stage['root'])!=normalized(path):raise ContractError('stage root mismatch')
  files=stage.get('files',[])
  if len(files)>MAX_FRAMES:raise ContractError('file limit')
  accepted={}
  for x in files:
   name=x.get('name','')
   if name in accepted:raise ContractError('duplicate frame')
   if name not in c['expected']:continue
   if not isinstance(x.get('bytes'),int) or x['bytes']<0 or not isinstance(x.get('modified'),str):raise ContractError('file metadata')
   if x.get('reparse',False):raise ContractError('reparse file')
   if x['bytes']>0:accepted[name]=x;frames.append({'stage':role,'name':name,'path':ntpath.join(path,name),'bytes':x['bytes'],'modified':x['modified']})
  for plan in c['plans']:planCounts[plan][role]=sum(name.startswith(plan+'_') for name in accepted)
  present[role]=len(accepted);missing[role]=sorted(set(c['expected'])-set(accepted))
 claims=[]
 for p in processes[:MAX_PROCESSES]:
  if str(p.get('name','')).lower() not in ('blender','blender.exe') or p.get('ownerVerified') is not True:continue
  if not isinstance(p.get('pid'),int) or not isinstance(p.get('birth'),str):continue
  t=tokens(p.get('argv'));script=take(t,'-P');out=take(t,'--anim');plan=take(t,'--plan')
  try:
   if script and out and normalized(script)==normalized(c['paths']['S']) and normalized(out)==normalized(c['paths']['OUT']) and plan in c['plans']:
    claims.append({'pid':p['pid'],'birth':p['birth'],'phase':'raw','plan':plan,'context':digest(json.dumps(t)),'binding':{'engine':'blender','ownerVerified':True,'scriptPath':script,'scriptSHA256':scriptHash,'outputRoot':out}})
   elif script and normalized(script)==normalized(c['paths']['PO']) and 'dossier' in t:
    i=t.index('dossier');inputRoot=t[i+1];output=t[i+2]
    if normalized(output)==normalized(c['paths']['POST']):
     for label in c['plans']:
      if normalized(inputRoot)==normalized(ntpath.join(c['paths']['F'],'post_'+label)):
       claims.append({'pid':p['pid'],'birth':p['birth'],'phase':'post','plan':label,'context':digest(json.dumps(t)),'binding':{'engine':'blender','ownerVerified':True,'scriptPath':script,'scriptSHA256':postHash,'outputRoot':output}})
  except (ContractError,IndexError):continue
 scope=digest(json.dumps([normalized(launcher['path']),normalized(c['paths']['S']),normalized(c['paths']['PO']),launcher['sha256'].lower(),scriptHash,postHash,c['plans'],normalized(c['paths']['F']),config.get('runToken','')],sort_keys=True,separators=(',',':'),ensure_ascii=False))
 # New execution/context cannot borrow an archived observed-process identity.
 session=scope # Worker PID/birth/argv are observation evidence, never a job/version identity.
 jobID='shadow:run:'+session
 provenance='process_observed' if claims else 'source_declared'
 diagnostics=[]
 for key,lines in source.get('logs',{}).items():
  text=' '.join(str(x) for x in lines).lower()
  if ('out of memory' in text or ('malloc' in text and ('failed' in text or 'error' in text)) or ('memory' in text and ('exhaust' in text or 'epuis' in text))):
   date=source.get('logTimes',{}).get(key)
   if date:diagnostics.append({'code':'memory_error','plan':key.split('.')[0],'observedAt':date})
 incomplete=present['raw']<c['total'] or present['post']<c['total']
 activity='running' if claims else ('countsReached' if not incomplete and process_coverage else ('resumeRequired' if diagnostics and incomplete and process_coverage else 'unknown'))
 return {'title':config.get('label') or ntpath.basename(ntpath.dirname(c['paths']['F'])),'id':jobID,'runID':session,'scopeID':scope,'sourceID':config['id'],'provenance':provenance,'observedAt':source['observedAt'],'launcherHash':launcher['sha256'].lower(),'scriptHash':scriptHash,'postScriptHash':postHash,'outputRoot':c['paths']['F'],'rawRoot':c['paths']['OUT'],'postRoot':c['paths']['POST'],'total':c['total'],'plans':c['plans'],'planCounts':planCounts,'rawCount':present['raw'],'postCount':present['post'],'missingRaw':missing['raw'],'missingPost':missing['post'],'frames':sorted(frames,key=lambda x:x['modified'],reverse=True)[:80],'claims':claims,'activity':activity,'diagnostics':diagnostics,'phases':sorted(set(x['phase'] for x in claims)),'logs':source.get('logs',{}),'processCoverage':process_coverage}
