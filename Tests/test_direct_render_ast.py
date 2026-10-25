"""AST-only regression checks. Never import bpy or execute any producer source."""
from pathlib import Path
import importlib.util,json,sys
ROOT=Path(__file__).resolve().parents[1]
path=ROOT/'Sources/RenduBar/Infrastructure/native_script_contract.py'
spec=importlib.util.spec_from_file_location('contract',path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
base="import bpy\nfrom pathlib import Path\ns=bpy.context.scene\ns.render.filepath=str(Path('/private/tmp/expected.png'))\nbpy.ops.render.render(write_still=True)\n"
checks=0
def infer(source):return m.infer_direct_render(source,'/fixture/producer.py','/fixture/scene.blend',[])
def check(value,label):
 global checks
 checks+=1
 assert value,label
value=infer(base);check(value['planned']==[1] and value['filenamePattern']=='/private/tmp/expected.png','literal direct still')
for label,source in [
 ('no render','import bpy\nprint(1)'),
 ('conditional','import bpy\nif True:\n bpy.ops.render.render(write_still=True)'),
 ('function-only','import bpy\ndef f():\n bpy.ops.render.render(write_still=True)'),
 ('operator rebound','import bpy\nbpy.ops.render.render=lambda:None\nbpy.ops.render.render(write_still=True)'),
 ('bpy reassigned',base.replace('s=bpy.context.scene','bpy=object()\ns=bpy.context.scene')),
 ('bpy for binding',base.replace('s=bpy.context.scene','for bpy in []: pass\ns=bpy.context.scene')),
 ('bpy import rebound',base.replace('s=bpy.context.scene','import fake as bpy\ns=bpy.context.scene'))]:
 try:infer(source)
 except m.Unsupported:check(True,label)
 else:raise AssertionError(label)
for label,source in [
 ('Path rebound',base.replace('s=bpy.context.scene',"Path=lambda ignored:'/private/tmp/different.png'\ns=bpy.context.scene")),
 ('scene alias rebound',base.replace('s.render.filepath','s=object()\ns.render.filepath')),
 ('Path function',base.replace('s=bpy.context.scene',"def Path(x): return '/private/tmp/different.png'\ns=bpy.context.scene")),
 ('str rebound',base.replace('s=bpy.context.scene',"str=lambda x:'/private/tmp/different.png'\ns=bpy.context.scene")),
 ('conditional scene binding',base.replace('s.render.filepath','if True: s=object()\ns.render.filepath')),
 ('conditional filepath override',base.replace('bpy.ops.render.render',"if True: s.render.filepath='/private/tmp/different.png'\nbpy.ops.render.render"))]:
 value=infer(source);check(value['filenamePattern']=='' and value['grammar']=='direct_top_level_render_v1',label+' loses only output inference')
print(json.dumps({'assertions':checks,'status':'PASS','producerExecuted':False,'network':False}))
