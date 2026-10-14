"""One-shot RO observer; no remote script execution, registry, task or renderer mutation."""
import base64,gzip,json,re,ntpath,datetime
from shadow_run_contract import contract,decode_source,normalized,ContractError,tokens,take,digest

def validate_configs(sources):
 if not isinstance(sources,list) or len(sources)>8:raise ContractError('source limit')
 for s in sources:
  if not isinstance(s.get('id'),str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',s['id']):raise ContractError('source id')
  for k in ['launcherPath','scriptPath','postScriptPath','outputRoot','rawRoot','postRoot']:normalized(s[k])
  if not all(normalized(s[k]).startswith(normalized(s['outputRoot']).rstrip('/')+'/') for k in ['rawRoot','postRoot']):raise ContractError('scope')
  if normalized(s['rawRoot'])==normalized(s['postRoot']):raise ContractError('stages')
  plans=s.get('plans',{})
  if not isinstance(plans,dict) or not plans or len(plans)>32:raise ContractError('plans')
  total=0;seen=set()
  for key,v in plans.items():
   if not re.fullmatch('[A-Za-z][A-Za-z0-9_-]{0,15}',key) or not isinstance(v,list) or len(v)!=2 or any(type(n)!=int for n in v) or v[0]<0 or v[1]<v[0] or v[1]-v[0]>20000:raise ContractError('range')
   r=set(range(v[0],v[1]+1))
   if seen&r:raise ContractError('overlap')
   seen|=r;total+=len(r)
  if total>20000:raise ContractError('plan limit')

PS=r'''
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$sources=@([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG__'))|ConvertFrom-Json)
$clock=[Diagnostics.Stopwatch]::StartNew();$partial=$false;$procs=@();$auto=@();$budget=4000
$candidates=@(Get-Process -Name 'blender*','python*','powershell*','ffmpeg*' -ErrorAction SilentlyContinue | Where-Object Id -ne $PID | Select-Object -First 13);if($candidates.Count -gt 12){$partial=$true};$candidates=@($candidates|Select-Object -First 12)
foreach($p in $candidates){if($clock.ElapsedMilliseconds -gt $budget){$partial=$true;break};try{$c=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id) -OperationTimeoutSec 1;$owner=Invoke-CimMethod -InputObject $c -MethodName GetOwner -OperationTimeoutSec 1;if($owner.ReturnValue -ne 0){$partial=$true;continue};if($owner.User -ine [Environment]::UserName){continue};$argv=[string]$c.CommandLine;if($argv.Length -gt 4096){$partial=$true;continue};$procs+=@{pid=$p.Id;parentPid=[int]$c.ParentProcessId;birth=$p.StartTime.ToUniversalTime().ToString('o');name=$p.ProcessName;ownerVerified=$true;argv=$argv};if($p.ProcessName -like 'powershell*' -and $argv -match '(?i)-File\s+"?([^"\r\n]+?\.ps1)(?:"|\s|$)'){$q=$Matches[1];if(Test-Path -LiteralPath $q -PathType Leaf){$z=Get-Item -LiteralPath $q;if($z.Length -le 32768 -and -not($z.Attributes -band [IO.FileAttributes]::ReparsePoint)){$auto+=@{path=$q;sha256=(Get-FileHash -LiteralPath $q -Algorithm SHA256).Hash;content=[IO.File]::ReadAllText($q)}}}}}catch{$partial=$true}}
function Tail([string]$path){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return @()};$m=Get-Item -LiteralPath $path;if($m.Attributes -band [IO.FileAttributes]::ReparsePoint){return @()};$f=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite);try{$n=[Math]::Min(8192,$f.Length);[void]$f.Seek(-$n,[IO.SeekOrigin]::End);$b=New-Object byte[] $n;$r=$f.Read($b,0,$n);return @([Text.Encoding]::UTF8.GetString($b,0,$r)-split '\r?\n' | Select-Object -Last 32)}finally{$f.Dispose()}}
$runs=@();foreach($s in $sources){if($clock.ElapsedMilliseconds -gt 9000){throw 'observation-time-budget'};$hashes=@();foreach($q in @($s.scriptPath,$s.postScriptPath)){$m=Get-Item -LiteralPath $q;if($m.Length -gt 262144 -or ($m.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'source-type-limit'};$hashes+=@{path=$q;sha256=(Get-FileHash -LiteralPath $q -Algorithm SHA256).Hash}}
$l=Get-Item -LiteralPath $s.launcherPath;if($l.Length -gt 32768 -or ($l.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'launcher-type-limit'}
$stages=@{};foreach($role in @('raw','post')){$dir=if($role -eq 'raw'){$s.rawRoot}else{$s.postRoot};$m=Get-Item -LiteralPath $dir;if(-not $m.PSIsContainer -or ($m.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'stage-type'};$files=@(Get-ChildItem -LiteralPath $dir -File -Filter '*.png' | Select-Object -First 20001 | ForEach-Object{@{name=$_.Name;bytes=$_.Length;modified=$_.LastWriteTimeUtc.ToString('o');reparse=[bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}});if($files.Count -gt 20000){throw 'frame-limit'};$stages[$role]=@{root=$dir;files=$files}}
$root=Get-Item -LiteralPath $s.outputRoot;$logs=@{};$logTimes=@{};$paths=@('journal.txt')+@($s.plans.PSObject.Properties.Name|ForEach-Object{$_.ToString()+'.log';$_.ToString()+'.log.err'});foreach($n in $paths){$q=Join-Path $s.outputRoot $n;$logs[$n]=@(Tail $q);if(Test-Path -LiteralPath $q -PathType Leaf){$logTimes[$n]=(Get-Item -LiteralPath $q).LastWriteTimeUtc.ToString('o')}}
$runs+=@{sourceID=$s.id;observedAt=[DateTime]::UtcNow.ToString('o');outputBirth=$root.CreationTimeUtc.ToString('o');launcher=@{path=$s.launcherPath;sha256=(Get-FileHash -LiteralPath $s.launcherPath -Algorithm SHA256).Hash;content=[IO.File]::ReadAllText($s.launcherPath)};sources=$hashes;stages=$stages;logs=$logs;logTimes=$logTimes}}
@{ok=$true;observedAt=[DateTime]::UtcNow.ToString('o');partial=$partial;processes=$procs;autoLaunchers=$auto;runs=$runs}|ConvertTo-Json -Depth 9 -Compress
'''

def ps_script(configs):return PS.replace('__CONFIG__',base64.b64encode(json.dumps(configs).encode()).decode())
BOOTSTRAP = r"""$ErrorActionPreference='Stop';$b=[Convert]::FromBase64String([Console]::In.ReadToEnd());$m=[IO.MemoryStream]::new($b);$z=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);$r=[IO.StreamReader]::new($z,[Text.Encoding]::UTF8);try{& ([ScriptBlock]::Create($r.ReadToEnd()))}finally{$r.Dispose();$z.Dispose();$m.Dispose()}"""

def stdin_transport(sources):
 script=ps_script(sources).encode('utf-8')
 if len(script)>131072:raise ContractError('script byte limit')
 command='powershell -NoProfile -NonInteractive -EncodedCommand '+base64.b64encode(BOOTSTRAP.encode('utf-16-le')).decode('ascii')
 payload=base64.b64encode(gzip.compress(script,mtime=0))+b'\n'
 return command,payload

def auto_configs(raw):
 result=[]
 for entry in raw.get('autoLaunchers',[])[:8]:
  try:
   c=contract(entry['path'],entry['content']);paths=c['paths'];result.append({'id':'auto_'+digest(normalized(entry['path']))[:24],'launcherPath':entry['path'],'scriptPath':paths['S'],'postScriptPath':paths['PO'],'outputRoot':paths['F'],'rawRoot':paths['OUT'],'postRoot':paths['POST'],'plans':c['plans'],'provenance':'process_observed'})
  except (ContractError,KeyError):continue
 return result

def decode(raw,configs,declared_ids=None):
 if raw.get('ok') is not True or not isinstance(raw.get('observedAt'),str) or len(raw.get('processes',[]))>24 or len(raw.get('runs',[]))>8:raise ContractError('invalid snapshot')
 declared=set(x['id'] for x in configs) if declared_ids is None else set(declared_ids)
 attestations=[];runs=[];seen=set();byid={s['id']:s for s in configs}
 for item in raw.get('runs',[]):
  s=byid.get(item.get('sourceID'))
  if not s or s['id'] in seen:raise ContractError('source mismatch')
  seen.add(s['id']);row=decode_source(item,s,raw.get('processes',[]),not raw.get('partial',True),raw['observedAt'])
  for k in ['outputRoot','rawRoot','postRoot']:
   if normalized(row[k])!=normalized(s[k]):raise ContractError('declared root mismatch')
  if row['plans']!=s['plans']:raise ContractError('declared plan mismatch')
  row['logs']={key:[re.sub(r'[A-Za-z]:[\\/][^\r\n\"\']+', '<private-path>',str(line))[:512] for line in lines[-8:]] for key,lines in row['logs'].items()}
  if s['id'] not in declared:
   candidate=next((x for x in raw.get('autoLaunchers',[]) if normalized(x['path'])==normalized(s['launcherPath']) and x.get('sha256','').lower()==row['launcherHash']),None)
   if candidate is None or not row['claims'] or row['provenance']!='process_observed':continue
   actual=next((x for x in auto_configs(raw) if x['id']==s['id']),None)
   if actual is None or any(actual[k]!=s[k] for k in ['launcherPath','scriptPath','postScriptPath','outputRoot','rawRoot','postRoot','plans']):raise ContractError('automatic descriptor mismatch')
   descriptor={k:v for k,v in s.items() if k!='provenance'};descriptor['expectedScriptSHA256']=row['scriptHash']
   attestations.append({'source':descriptor,'runID':row['runID'],'launcherHash':row['launcherHash'],'observedAt':row['observedAt'],'claims':row['claims']})
  runs.append(row)
 if set(byid)!=seen:raise ContractError('truncated source snapshot')
 return {'ok':True,'observedAt':raw['observedAt'],'partial':bool(raw.get('partial')),'runs':runs,'automaticSources':attestations}

def observe(configs,connection,ssh_base,run):
 validate_configs(configs);declared_ids=[x['id'] for x in configs];host,user,key=connection()
 def fetch(sources):
  command,payload=stdin_transport(sources);data=run(['ssh',*ssh_base(key),'-T','-o','ControlMaster=no','-o','ControlPath=none',f'{user}@{host}',command],12,input_bytes=payload)
  if len(data)>1024*1024:raise ContractError('snapshot bytes')
  return json.loads(data.decode('utf-8-sig'))
 raw=fetch(configs);new=auto_configs(raw);extra=[s for s in new if normalized(s['launcherPath']) not in {normalized(x['launcherPath']) for x in configs}]
 # No daemon: at most one follow-up for newly argv-discovered supported launchers.
 if extra and len(configs)+len(extra)<=8:
  configs=configs+extra;validate_configs(configs);raw=fetch(configs)
 return decode(raw,configs,declared_ids)
