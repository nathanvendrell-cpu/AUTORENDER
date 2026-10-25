"""Pure, fail-closed AST adapter for the supported per-frame Python producer.
Never imports or executes the source. Paths and prefixes come from its AST.
"""
import ast,hashlib,json,re
from pathlib import Path
class Unsupported(ValueError):pass
class Unavailable(Unsupported):pass
def dump(node):return ast.dump(node,include_attributes=False)
def expression(text):return dump(ast.parse(text,mode='eval').body)
def infer(source,script_path,scene,argv):
 if not isinstance(source,str) or len(source.encode())>32768 or len(argv)>256:raise Unsupported('limit')
 tree=ast.parse(source);nodes=tree.body
 for node in ast.walk(tree):
  if isinstance(node,(ast.Global,ast.Nonlocal)):raise Unsupported('dynamic binding')
  if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id in ['exec','eval','globals','locals','setattr','delattr','__import__','compile']:raise Unsupported('dynamic execution')

 # Supported identities and assignments; reject overrides, aliases or conditional bindings.
 assignments={}
 for node in nodes:
  if isinstance(node,ast.Assign):
   for target in node.targets:
    if isinstance(target,ast.Name):assignments.setdefault(target.id,[]).append(node.value)
    elif isinstance(target,ast.Tuple):
     if all(isinstance(x,ast.Name) for x in target.elts) and isinstance(node.value,(ast.Tuple,ast.List)) and len(target.elts)==len(node.value.elts):
      for name,value in zip(target.elts,node.value.elts):assignments.setdefault(name.id,[]).append(value)
 def value(name):
  values=assignments.get(name,[])
  if len(values)!=1:raise Unsupported('binding')
  return values[0]
 tracked={'R','A','variant','mode','frames_arg','frames','out','progress'}
 for node in ast.walk(tree):
  if isinstance(node,(ast.AugAssign,ast.AnnAssign,ast.NamedExpr)) and isinstance(node.target,ast.Name) and node.target.id in tracked:raise Unsupported('override')
  if isinstance(node,ast.Assign) and node not in nodes and any(isinstance(t,ast.Name) and t.id in tracked for t in node.targets):raise Unsupported('conditional binding')
 functions=[x for x in nodes if isinstance(x,ast.FunctionDef) and x.name=='arg']
 expected=ast.parse("def arg(key, default):\n return A[A.index(key)+1] if key in A else default").body[0]
 if len(functions)!=1 or dump(functions[0])!=dump(expected):raise Unsupported('argument grammar')
 if dump(value('A'))!=expression("sys.argv[sys.argv.index('--')+1:]"):raise Unsupported('argv grammar')
 root_node=value('R');root_match=re.fullmatch(r"Path\(__file__\)\.resolve\(\)\.parents\[(\d+)\]",ast.unparse(root_node))
 if not root_match or int(root_match[1])>3:raise Unsupported('root grammar')
 script=Path(script_path);scene_path=Path(scene)
 if not script.is_absolute() or not scene_path.is_absolute():raise Unsupported('absolute paths')
 root=script.resolve().parents[int(root_match[1])]
 if not scene_path.resolve().is_relative_to(root):raise Unsupported('scene scope')
 args=argv[argv.index('--')+1:] if '--' in argv else []
 if len(args)%2 or len(args)>6:raise Unsupported('argument count')
 supplied={}
 for key,val in zip(args[::2],args[1::2]):
  if key not in ['--variant','--mode','--frames'] or key in supplied:raise Unsupported('argument keys')
  supplied[key]=val
 def option(name,key):
  node=value(name)
  if not isinstance(node,ast.Call) or not isinstance(node.func,ast.Name) or node.func.id!='arg' or len(node.args)!=2 or node.keywords:raise Unsupported('option grammar')
  if not isinstance(node.args[0],ast.Constant) or node.args[0].value!=key or not isinstance(node.args[1],ast.Constant) or not isinstance(node.args[1].value,str):raise Unsupported('option binding')
  return supplied.get(key,node.args[1].value)
 variant=option('variant','--variant');mode=option('mode','--mode');frames_arg=option('frames_arg','--frames')
 if any(re.fullmatch(r'[A-Za-z0-9_-]{1,80}',x) is None for x in [variant,mode]):raise Unsupported('scope tokens')
 frames_node=value('frames')
 if not isinstance(frames_node,ast.IfExp) or dump(frames_node.test)!=expression("frames_arg == 'all'") or dump(frames_node.orelse)!=expression("[int(x) for x in frames_arg.split(',')]"):raise Unsupported('frame grammar')
 call=frames_node.body
 if not isinstance(call,ast.Call) or ast.unparse(call.func)!='list' or len(call.args)!=1:raise Unsupported('frame range')
 range_call=call.args[0]
 if not isinstance(range_call,ast.Call) or ast.unparse(range_call.func)!='range' or len(range_call.args)!=2 or not all(isinstance(x,ast.Constant) and isinstance(x.value,int) for x in range_call.args):raise Unsupported('frame range')
 first,last=[x.value for x in range_call.args]
 if not 0<first<last<=10001:raise Unsupported('range limit')
 if frames_arg=='all':planned=list(range(first,last))
 else:
  if re.fullmatch(r'[0-9]+(?:,[0-9]+)*',frames_arg) is None:raise Unsupported('frame values')
  planned=[int(x) for x in frames_arg.split(',')]
 if not planned or len(planned)>10000 or len(set(planned))!=len(planned) or any(x<1 or x>1000000 for x in planned):raise Unsupported('planned frames')
 def scoped_path(node):
  if not isinstance(node,ast.BinOp) or not isinstance(node.op,ast.Div):raise Unsupported('path grammar')
  if not isinstance(node.left,ast.BinOp) or not isinstance(node.left.op,ast.Div) or not isinstance(node.left.left,ast.Name) or node.left.left.id!='R' or not isinstance(node.left.right,ast.Constant) or not isinstance(node.left.right.value,str):raise Unsupported('path root')
  folder=node.left.right.value
  if re.fullmatch(r'[A-Za-z0-9_-]{1,80}',folder) is None or not isinstance(node.right,ast.JoinedStr):raise Unsupported('path leaf')
  leaf=''
  for part in node.right.values:
   if isinstance(part,ast.Constant) and isinstance(part.value,str):leaf+=part.value
   elif isinstance(part,ast.FormattedValue) and isinstance(part.value,ast.Name) and part.format_spec is None and part.conversion==-1 and part.value.id in ['variant','mode']:leaf+=variant if part.value.id=='variant' else mode
   else:raise Unsupported('path template')
  if '/' in leaf or '\\' in leaf or leaf in ['.','..']:raise Unsupported('leaf traversal')
  return root/folder/leaf
 output=scoped_path(value('out'));metadata=scoped_path(value('progress'))
 if metadata.suffix!='.json' or output==metadata or metadata.is_relative_to(output):raise Unsupported('separate metadata')
 loops=[x for x in nodes if isinstance(x,ast.For) and isinstance(x.target,ast.Name) and x.target.id=='f' and isinstance(x.iter,ast.Name) and x.iter.id=='frames']
 if len(loops)!=1:raise Unsupported('render loop')
 loop=loops[0];dest=[x for x in loop.body if isinstance(x,ast.Assign) and len(x.targets)==1 and isinstance(x.targets[0],ast.Name) and x.targets[0].id=='dest']
 if len(dest)!=1 or not isinstance(dest[0].value,ast.BinOp) or ast.unparse(dest[0].value.left)!='out' or not isinstance(dest[0].value.op,ast.Div) or not isinstance(dest[0].value.right,ast.JoinedStr):raise Unsupported('filename grammar')
 pattern='';tokens=0
 for part in dest[0].value.right.values:
  if isinstance(part,ast.Constant) and isinstance(part.value,str):pattern+=part.value
  elif isinstance(part,ast.FormattedValue) and ast.unparse(part.value)=='f' and part.conversion==-1 and isinstance(part.format_spec,ast.JoinedStr) and len(part.format_spec.values)==1 and isinstance(part.format_spec.values[0],ast.Constant) and part.format_spec.values[0].value=='04d':pattern+='####';tokens+=1
  else:raise Unsupported('filename token')
 if tokens!=1 or '/' in pattern or '\\' in pattern or not pattern.endswith('.png') or len(pattern)>128:raise Unsupported('filename')
 required=["sc.frame_set(f)","sc.render.filepath = str(dest)","bpy.ops.render.render(write_still=True)"]
 if any(not any(dump(x)==dump(ast.parse(line).body[0]) for x in loop.body) for line in required):raise Unsupported('render association')
 writes=[x for x in loop.body if isinstance(x,ast.Expr) and isinstance(x.value,ast.Call) and ast.unparse(x.value.func)=='progress.write_text']
 if len(writes)!=1 or not writes[0].value.args:raise Unsupported('metadata writer')
 serialization=writes[0].value.args[0]
 if not isinstance(serialization,ast.Call) or ast.unparse(serialization.func)!='json.dumps' or not serialization.args or not isinstance(serialization.args[0],ast.Dict):raise Unsupported('metadata serialization')
 schema=serialization.args[0];fields={k.value:v for k,v in zip(schema.keys,schema.values) if isinstance(k,ast.Constant)}
 if ast.unparse(fields.get('planned',ast.Constant(None)))!='frames' or ast.unparse(fields.get('completed',ast.Constant(None)))!='results':raise Unsupported('metadata schema')
 return {'scriptSHA256':hashlib.sha256(source.encode()).hexdigest(),'scene':str(scene_path),'metadataPath':str(metadata),'outputRoot':str(output),'filenamePattern':pattern,'planned':planned,'plannedKey':'planned','completedKey':'completed','frameKey':'frame','secondsKey':'seconds','variant':variant,'mode':mode,'grammar':'static_per_frame_python_v1','executionRunAttested':False}
def validate_progress(descriptor,metadata):
 if not isinstance(metadata,dict) or metadata.get('variant')!=descriptor['variant'] or metadata.get('mode')!=descriptor['mode'] or metadata.get('planned')!=descriptor['planned']:raise Unsupported('progress scope')
 rows=metadata.get('completed')
 if not isinstance(rows,list) or len(rows)>len(descriptor['planned']):raise Unsupported('completed records')
 seen=set()
 for row in rows:
  if not isinstance(row,dict) or type(row.get('frame')) is not int or row['frame'] not in descriptor['planned'] or row['frame'] in seen:raise Unsupported('completed scope')
  if not isinstance(row.get('seconds'),(int,float)) or not 0<row['seconds']<86400 or type(row.get('bytes')) is not int or row['bytes']<=0:raise Unsupported('completed metadata')
  seen.add(row['frame'])
 return {'total':len(descriptor['planned']),'records':len(rows),'counterFromRecordListOnly':False,'requiresStableFileValidation':True}
def infer_direct_render(source,script_path,scene,argv):
 """A direct top-level render invocation establishes task intent, never current GPU activity."""
 tree=ast.parse(source)
 if not any(isinstance(n,ast.Import) and any(x.name=='bpy' and x.asname is None for x in n.names) for n in tree.body):raise Unsupported('direct bpy import')
 render_calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and ast.unparse(n.func)=='bpy.ops.render.render']
 direct=[n.value for n in tree.body if isinstance(n,(ast.Expr,ast.Assign)) and isinstance(n.value,ast.Call) and ast.unparse(n.value.func)=='bpy.ops.render.render']
 if len(direct)!=1 or len(render_calls)!=1:raise Unsupported('direct unconditional invocation')
 call=direct[0]
 if call.args or any(k.arg is None for k in call.keywords):raise Unsupported('direct operator arguments')
 for n in ast.walk(tree):
  if isinstance(n,(ast.Global,ast.Nonlocal)):raise Unsupported('dynamic binding')
  if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id in ('exec','eval','compile','setattr','delattr','globals','locals'):raise Unsupported('dynamic execution')
  if isinstance(n,ast.Name) and isinstance(n.ctx,(ast.Store,ast.Del)) and n.id=='bpy':raise Unsupported('bpy rebound')
  if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)) and n.name=='bpy':raise Unsupported('bpy rebound')
  if isinstance(n,ast.Import) and any((x.asname or x.name.split('.')[0])=='bpy' and (x.name!='bpy' or x.asname is not None) for x in n.names):raise Unsupported('bpy import rebound')
  if isinstance(n,ast.ImportFrom) and any((x.asname or x.name)=='bpy' for x in n.names):raise Unsupported('bpy import rebound')
  if isinstance(n,(ast.Assign,ast.AnnAssign,ast.AugAssign)):
   targets=n.targets if isinstance(n,ast.Assign) else [n.target]
   if any(ast.unparse(t)=='bpy' or ast.unparse(t).startswith('bpy.ops') for t in targets):raise Unsupported('operator rebound')
 keywords={k.arg:k.value for k in call.keywords}
 animation=keywords.get('animation',ast.Constant(False));still=keywords.get('write_still',ast.Constant(False))
 if not isinstance(animation,ast.Constant) or type(animation.value) is not bool:raise Unsupported('unknown render mode')
 if not isinstance(still,ast.Constant) or type(still.value) is not bool:raise Unsupported('unknown write mode')
 # Resolve a narrow literal Path grammar; never eval/import the producer or run its expressions.
 env={};aliases=set();output='';output_alias=None;path_trusted=False;str_trusted=True
 def literal(n):
  if isinstance(n,ast.Constant) and isinstance(n.value,str):return n.value
  if isinstance(n,ast.Name) and n.id in env:return env[n.id]
  if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and ((n.func.id=='Path' and path_trusted) or (n.func.id=='str' and str_trusted)) and len(n.args)==1 and not n.keywords:return literal(n.args[0])
  if isinstance(n,ast.BinOp) and isinstance(n.op,ast.Div):return str(Path(literal(n.left))/literal(n.right))
  raise Unsupported('nonliteral path')
 for n in tree.body:
  if getattr(n,'lineno',0)>=call.lineno:break
  if isinstance(n,ast.ImportFrom) and n.module=='pathlib' and any(x.name=='Path' and x.asname is None for x in n.names):path_trusted=True
  if isinstance(n,ast.Assign):
   for target in n.targets:
    if isinstance(target,ast.Name):
     if target.id=='Path':path_trusted=False;output=''
     if target.id=='str':str_trusted=False;output=''
     aliases.discard(target.id)
     if output_alias==target.id:output='';output_alias=None
     if ast.unparse(n.value)=='bpy.context.scene':aliases.add(target.id)
     try:env[target.id]=literal(n.value)
     except Unsupported:env.pop(target.id,None)
    elif ast.unparse(target) in {a+'.render.filepath' for a in aliases}:
     try:output=literal(n.value);output_alias=ast.unparse(target).split('.')[0]
     except Unsupported:output='';output_alias=None
  else:
   # Unhandled bindings (including conditional/loop/import/function bindings) only lose output inference.
   if any(isinstance(x,ast.Attribute) and isinstance(x.ctx,(ast.Store,ast.Del)) and ast.unparse(x) in {a+'.render.filepath' for a in aliases} for x in ast.walk(n)):output='';output_alias=None
   rebound={x.id for x in ast.walk(n) if isinstance(x,ast.Name) and isinstance(x.ctx,(ast.Store,ast.Del))}
   if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef)):rebound.add(n.name)
   if isinstance(n,(ast.Import,ast.ImportFrom)):
    rebound.update(x.asname or x.name.split('.')[0] for x in n.names)
    if isinstance(n,ast.ImportFrom) and n.module=='pathlib':rebound.discard('Path')
   if 'Path' in rebound:path_trusted=False;output=''
   if 'str' in rebound:str_trusted=False;output=''
   for name in rebound:
    aliases.discard(name);env.pop(name,None)
    if output_alias==name:output='';output_alias=None
 if output and (not Path(output).is_absolute() or len(output.encode())>4096 or any(ord(c)<32 for c in output)):output=''
 if animation.value or not still.value:output=''
 return {'scriptSHA256':hashlib.sha256(source.encode()).hexdigest(),'scene':scene,'metadataPath':'','outputRoot':str(Path(output).parent) if output else '',
         'filenamePattern':str(Path(output)) if output else '', 'planned':[1] if not animation.value else [],'plannedKey':'planned','completedKey':'completed','frameKey':'frame','secondsKey':'seconds',
         'variant':'direct_render','mode':'animation' if animation.value else 'still','grammar':'direct_top_level_render_v1','executionRunAttested':False}

def infer_snapshot(snapshot,static_only=False):
 """Automatic in-memory binding from a canonical same-user process snapshot.
 Caller must recheck the process identity after IO, exactly as NativeRenderDiscovery.
 """
 identity=snapshot['identity'];argv=snapshot['arguments'];scene=snapshot['scene'];script=snapshot['script']
 if type(identity.get('birthSeconds')) is not int or identity['birthSeconds']<=0 or type(identity.get('birthMicroseconds')) is not int or not 0<=identity['birthMicroseconds']<1000000:raise Unsupported('birth identity')
 prefix=argv[:argv.index('--')] if '--' in argv else argv
 scenes=[x for x in prefix if isinstance(x,str) and x.lower().endswith('.blend')]
 if len(scenes)!=1 or str(Path(scenes[0]).resolve())!=str(Path(scene).resolve()):raise Unsupported('scene argument binding')
 if snapshot.get('sameUser') is not True or Path(identity['executable']).name.lower()!='blender' or type(identity.get('pid')) is not int or identity['pid']<=0:raise Unsupported('producer identity')
 if not any(token in ['--python','-P'] and index+1<len(argv) and argv[index+1]==script for index,token in enumerate(argv)):raise Unsupported('script argument binding')
 path=Path(script)
 if path.is_symlink() or not path.is_file() or path.stat().st_size>32768:raise Unsupported('script file')
 before=path.stat();birth=identity['birthSeconds']+identity['birthMicroseconds']/1000000
 if before.st_mtime>birth:raise Unsupported('script modified after process birth')
 raw_source=path.read_bytes();source=raw_source.decode("utf-8");after=path.stat()
 if (before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_ino,after.st_size,after.st_mtime_ns):raise Unsupported('source changed')
 try:descriptor=infer(source,script,scene,argv)
 except Unsupported:descriptor=infer_direct_render(source,script,scene,argv)
 descriptor["scriptSHA256"]=hashlib.sha256(raw_source).hexdigest()
 descriptor['metadataFingerprint']=None
 if not static_only and descriptor["grammar"]!="direct_top_level_render_v1":
  try:
   metadata_path=Path(descriptor['metadataPath']);output=Path(descriptor['outputRoot'])
   if metadata_path.is_symlink() or not metadata_path.is_file() or metadata_path.stat().st_size>32768 or output.is_symlink() or not output.is_dir():raise Unsupported('scope files')
   metadata_before=metadata_path.stat();metadata=json.loads(metadata_path.read_text());metadata_after=metadata_path.stat()
   if (metadata_before.st_ino,metadata_before.st_size,metadata_before.st_mtime_ns)!=(metadata_after.st_ino,metadata_after.st_size,metadata_after.st_mtime_ns):raise Unsupported('metadata changed during read')
   validate_progress(descriptor,metadata)
  except (Unsupported,OSError,ValueError) as error:
   raise Unavailable("qualified producer metadata unavailable") from error
  descriptor['metadataFingerprint']={'device':metadata_after.st_dev,'inode':metadata_after.st_ino,'bytes':metadata_after.st_size,'modified':metadata_after.st_mtime}
 mapping={'processIdentity':identity,'scene':scene,'metadataPath':descriptor['metadataPath'],'outputRoot':descriptor['outputRoot'],'filenamePattern':descriptor['filenamePattern'],'plannedKey':'planned','completedKey':'completed','frameKey':'frame','secondsKey':'seconds','maximumBytes':32768,'exclusiveOutputScope':False,'workType':'video'}
 return {'mapping':mapping,'descriptor':descriptor,'provenance':'AST supported producer + exact current argv/scene/script hash + metadata contract; no manual config','requiresProcessRecheck':True,'requiresStableFileValidation':True,'activityNotAssertedFromPIDOrCounter':True}

def main():
 import sys
 try:
  raw=sys.stdin.buffer.read(131073)
  if len(raw)>131072:raise Unsupported('input limit')
  snapshot=json.loads(raw)
  result=infer_snapshot(snapshot,static_only=snapshot.get("staticOnly") is True)
  print(json.dumps({'ok':True,'result':result},ensure_ascii=False))
 except Exception as error:
  print(json.dumps({'ok':False,'reason':type(error).__name__}))
 return 0
if __name__=='__main__':raise SystemExit(main())
