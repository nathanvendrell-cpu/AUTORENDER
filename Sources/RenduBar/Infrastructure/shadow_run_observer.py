"""One-shot RO observer; no remote script execution, registry, task or renderer mutation."""
import base64,gzip,json,re,ntpath,datetime
from pathlib import Path
from standard_render_observation import snapshot as process_snapshot
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

PS_PATH = Path(__file__).with_name('shadow_process_observer.ps1')


def ps_script(configs):
 return PS_PATH.read_text(encoding='utf-8').replace('__CONFIG__',base64.b64encode(json.dumps(configs).encode()).decode())
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

def decode(raw, configs, declared_ids=None):
    modern = raw.get('processSchema') == 1
    limit = 64 if modern else 24
    if raw.get('ok') is not True or not isinstance(raw.get('observedAt'), str) or len(raw.get('processes', [])) > limit or len(raw.get('runs', [])) > 8:
        raise ContractError('invalid snapshot')
    declared = set(x['id'] for x in configs) if declared_ids is None else set(declared_ids)
    byid = {source['id']: source for source in configs}
    errors = []
    if modern:
        for item in raw.get('sourceErrors', []):
            if not isinstance(item, dict) or item.get('sourceID') not in byid:
                raise ContractError('source error scope')
            if item['sourceID'] not in errors:
                errors.append(item['sourceID'])
    process = process_snapshot(raw) if modern else None
    processes = raw.get('processes', [])
    if process is not None:
        eligible = {(row['pid'], row['birth']) for row in process['observations']}
        processes = [row for row in processes if isinstance(row, dict) and type(row.get('pid')) is int and isinstance(row.get('birth'), str) and (row['pid'], row['birth']) in eligible]
    attestations, runs, seen = [], [], set()
    for item in raw.get('runs', []):
        source = byid.get(item.get('sourceID'))
        if not source or source['id'] in seen:
            raise ContractError('source mismatch')
        seen.add(source['id'])
        try:
            coverage = process['coverageComplete'] if process is not None else not raw.get('partial', True)
            row = decode_source(item, source, processes, coverage, raw['observedAt'])
            for key in ['outputRoot', 'rawRoot', 'postRoot']:
                if normalized(row[key]) != normalized(source[key]):
                    raise ContractError('declared root mismatch')
            if row['plans'] != source['plans']:
                raise ContractError('declared plan mismatch')
            row['logs'] = {key: [re.sub(r"[A-Za-z]:[\\/][^\r\n\"']+", '<private-path>', str(line))[:512] for line in lines[-8:]] for key, lines in row['logs'].items()}
            if source['id'] not in declared:
                candidate = next((x for x in raw.get('autoLaunchers', []) if normalized(x['path']) == normalized(source['launcherPath']) and x.get('sha256', '').lower() == row['launcherHash']), None)
                if candidate is None or not row['claims'] or row['provenance'] != 'process_observed':
                    continue
                actual = next((x for x in auto_configs(raw) if x['id'] == source['id']), None)
                if actual is None or any(actual[key] != source[key] for key in ['launcherPath', 'scriptPath', 'postScriptPath', 'outputRoot', 'rawRoot', 'postRoot', 'plans']):
                    raise ContractError('automatic descriptor mismatch')
                descriptor = {key: value for key, value in source.items() if key != 'provenance'}
                descriptor['expectedScriptSHA256'] = row['scriptHash']
                attestations.append({'source': descriptor, 'runID': row['runID'], 'launcherHash': row['launcherHash'], 'observedAt': row['observedAt'], 'claims': row['claims']})
            runs.append(row)
        except (ContractError, KeyError, TypeError, ValueError):
            if not modern:
                raise
            if source['id'] not in errors:
                errors.append(source['id'])
    missing = set(byid) - seen
    if missing and not modern:
        raise ContractError('truncated source snapshot')
    errors.extend(sorted(missing - set(errors)))
    result = {'ok': True, 'observedAt': raw['observedAt'], 'partial': bool(raw.get('partial')) or bool(errors), 'runs': runs, 'automaticSources': attestations}
    if modern:
        claimed = {(claim['pid'], claim['birth']) for row in runs for claim in row['claims']}
        process['observations'] = [row for row in process['observations'] if (row['pid'], row['birth']) not in claimed]
        result['processSnapshot'] = process
        result['partial'] = result['partial'] or not process['coverageComplete']
        result['sourceErrors'] = errors
    return result

def observe(configs,connection,ssh_base,run):
 validate_configs(configs);declared_ids=[x['id'] for x in configs];host,user,key=connection()
 def fetch(sources):
  command,payload=stdin_transport(sources);data=run(['ssh',*ssh_base(key),'-T','-o','ControlMaster=no','-o','ControlPath=none',f'{user}@{host}',command],12,input_bytes=payload)
  if len(data)>1024*1024:raise ContractError('snapshot bytes')
  raw = json.loads(data.decode('utf-8-sig'))
  raw['connectionScope'] = digest(host+'|'+user)
  return raw
 raw=fetch(configs);new=auto_configs(raw);extra=[s for s in new if normalized(s['launcherPath']) not in {normalized(x['launcherPath']) for x in configs}]
 # No daemon: at most one follow-up for newly argv-discovered supported launchers.
 if extra and len(configs)+len(extra)<=8:
  configs=configs+extra;validate_configs(configs);raw=fetch(configs)
 return decode(raw,configs,declared_ids)
