import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/RenduBar/Infrastructure'))
from standard_render_observation import snapshot, windows_arguments
from shadow_run_observer import decode, ps_script
from blender_render_relay import Relay
import test_shadow_run_observer as legacy

NOW = dt.datetime.now(dt.timezone.utc)
def stamp(delta=0): return (NOW + dt.timedelta(seconds=delta)).isoformat()
def process(pid=42, engine='blender', arguments=None):
    exe = 'C:\\Apps\\' + engine + '.exe'
    return dict(pid=pid, name=engine, birth=stamp(-1000), birthToken='133999999999999999', executable=exe, ownerVerified=True, revalidated=True,
                argv=arguments or ('"' + exe + '" -b "C:\\scene.blend" -s 1 -e 60 -a' if engine=='blender' else '"'+exe+'" -i C:\\in.mp4 -t 60 -frames:v 600 -progress C:\\progress.txt C:\\out.mp4'))
def packet(rows): return dict(ok=True, processSchema=1, observedAt=stamp(), processPartial=False, partial=False, processes=rows, runs=[], sourceErrors=[])
def relay(row, state='active', token='a'*32, observed=None):
    event = dict(schemaVersion=1,pid=row['pid'],birthToken=row['birthToken'],invocationToken=token,startedAt=stamp(-400),eventAt=stamp(-207),observedAt=observed or stamp(),state=state,phase=state if state in ['complete','cancel'] else 'pre',completedFrames=0,writtenFrames=0,durationsSeconds=[],title='Scene',mode='unknown',currentFrame=-2,jobRunning=state=='active')
    row['blenderRelay']=dict(text=json.dumps(event),modified=event['observedAt'])
    return event

def sample(row, text, modified=None): row['progressFile']=dict(path='C:\\progress.txt',text=text,modified=modified or stamp())

class StandardTests(unittest.TestCase):
    def result(self,row):return snapshot(packet([row]))['observations']
    def test_50_concurrent_no_manual_projects(self):
        value=snapshot(packet([process(pid=n+1) for n in range(50)]))
        self.assertTrue(value['coverageComplete']);self.assertEqual(len(value['observations']),50)
        self.assertTrue(all(r['qualified'] for r in value['observations']));self.assertEqual(len({r['id'] for r in value['observations']}),50)
    def test_cap_and_partial(self):
        value=snapshot(packet([process(pid=n+1) for n in range(64)]));self.assertFalse(value['coverageComplete']);self.assertEqual(len(value['observations']),50)
        with self.assertRaises(ValueError):snapshot(packet([process(pid=n+1) for n in range(65)]))
    def test_helper_priority_not_python_interpretation(self):
        row=process();row['executable']='C:\\python.exe';row['name']='python';self.assertEqual(self.result(row),[])
    def test_pid_reuse_identity(self):
        a=process();b=copy.deepcopy(a);b['birth']=stamp(-900)
        self.assertNotEqual(self.result(a)[0]['id'],self.result(b)[0]['id'])
    def test_owner_revalidation_and_missing_identity_partial(self):
        for key,value in [('ownerVerified',False),('revalidated',False),('birth',stamp(1)),('pid',0),('executable','')]:
            row=process();row[key]=value;result=snapshot(packet([row]));self.assertFalse(result['coverageComplete']);self.assertEqual(result['observations'],[])
    def test_duplicate_pid_partial_keeps_one(self):
        row=process();value=snapshot(packet([row,row]));self.assertFalse(value['coverageComplete']);self.assertEqual(len(value['observations']),1)
    def test_gui_presence_only_candidate(self):
        row=process(arguments='"C:\\Apps\\blender.exe" "C:\\scene.blend"');self.assertFalse(self.result(row)[0]['qualified'])
    def test_spoof_argv_candidate(self):
        row=process();row['argv']='C:\\other.exe -b C:\\scene.blend -a';self.assertFalse(self.result(row)[0]['qualified'])
    def test_long_frame_active_without_recent_output(self):
        row=self.result(process())[0];self.assertTrue(row['qualified']);self.assertIsNone(row['completedFrames']);self.assertEqual(row['totalFrames'],60)
    def test_blender_argument_order_resets_total(self):
        row=process(arguments='C:\\Apps\\blender.exe -b -s 1 -e 60 C:\\scene.blend -a');self.assertIsNone(self.result(row)[0]['totalFrames'])
    def test_blender_single_and_unknown_option(self):
        row=process(arguments='C:\\Apps\\blender.exe -b C:\\scene.blend -f 42');self.assertEqual(self.result(row)[0]['totalFrames'],1)
        row['argv']+=' --unknown';self.assertFalse(self.result(row)[0]['qualified'])
    def test_windows_quoting_and_bound(self):
        self.assertEqual(windows_arguments('"C:\\App Folder\\blender.exe" -b "C:\\my scene.blend"'),['C:\\App Folder\\blender.exe','-b','C:\\my scene.blend'])
        self.assertIsNone(windows_arguments('"unclosed'));self.assertIsNone(windows_arguments('x'*4097))
    def producer(self,text):
        row=process(arguments='C:\\Apps\\blender.exe -b -P C:\\render.py')
        row['producerSource']=dict(path='C:\\render.py',text=text,modified=stamp(-1100),sha256=hashlib.sha256(text.encode()).hexdigest())
        return row
    def test_static_producer_and_dormant_function(self):
        self.assertTrue(self.result(self.producer('import bpy\nbpy.ops.render.render(animation=True)'))[0]['qualified'])
        self.assertFalse(self.result(self.producer('import bpy\ndef dormant():\n bpy.ops.render.render(animation=True)'))[0]['qualified'])
    def test_static_called_main_function(self):
        row=self.producer("import bpy\ndef main():\n bpy.ops.render.render(write_still=True)\nif __name__ == '__main__':\n main()")
        self.assertEqual(self.result(row)[0]['evidence'],'static_producer')
    def test_static_spoof_changed_and_unreachable(self):
        for text in ['import bpy\nbpy.ops.render.render=lambda **k: None\nbpy.ops.render.render(animation=True)','import bpy\nraise RuntimeError()\nbpy.ops.render.render(animation=True)','import bpy\nfor x in [1]:\n break\n bpy.ops.render.render(animation=True)','import bpy\nimport sys\nsys.exit()\nbpy.ops.render.render(animation=True)']:
            self.assertFalse(self.result(self.producer(text))[0]['qualified'])
        row=self.producer('import bpy\nbpy.ops.render.render(animation=True)');row['producerSource']['sha256']='f'*64;self.assertFalse(self.result(row)[0]['qualified'])
    def test_ffmpeg_frames_and_seconds_are_separate(self):
        row=process(engine='ffmpeg');sample(row,'frame=17\nout_time_us=3500000\nprogress=continue\n');value=self.result(row)[0]
        self.assertEqual(value['completedFrames'],17);self.assertEqual(value['mediaPositionSeconds'],3.5);self.assertEqual(value['totalFrames'],600);self.assertEqual(value['mediaDurationSeconds'],60)
    def test_legacy_out_time_ms_is_microseconds(self):
        row=process(engine='ffmpeg');sample(row,'frame=17\nout_time_ms=3500000\nprogress=continue\n');self.assertEqual(self.result(row)[0]['mediaPositionSeconds'],3.5)
    def test_time_not_a_frame_or_percentage(self):
        row=process(engine='ffmpeg');sample(row,'out_time_us=3500000\nprogress=continue\n');self.assertIsNone(self.result(row)[0]['completedFrames'])
    def test_shared_progress_not_attributed(self):
        rows=[process(1,'ffmpeg'),process(2,'ffmpeg')]
        for row in rows:sample(row,'frame=17\nprogress=continue\n')
        self.assertTrue(all(r['qualified'] and r['completedFrames'] is None for r in snapshot(packet(rows))['observations']))
    def test_progress_future_before_birth_and_partial_block(self):
        for modified in [stamp(1),stamp(-2000)]:
            row=process(engine='ffmpeg');sample(row,'frame=600\nprogress=end\n',modified);self.assertIsNone(self.result(row)[0]['completedFrames'])
        row=process(engine='ffmpeg');sample(row,'frame=600\nprogress=end\nframe=2\n');self.assertFalse(self.result(row)[0]['completedSignal'])
        sample(row,'frame=3\nprogress=continue\nframe=600\n');self.assertEqual(self.result(row)[0]['completedFrames'],3)
    def test_end_requires_exact_declared_frames(self):
        row=process(engine='ffmpeg');sample(row,'frame=599\nprogress=end\n');self.assertFalse(self.result(row)[0]['completedSignal'])
        sample(row,'frame=600\nprogress=end\n');self.assertTrue(self.result(row)[0]['completedSignal'])
    def test_cli_unknown_total_preserved(self):
        row=process(engine='ffmpeg');row['argv']='C:\\Apps\\ffmpeg.exe -i C:\\in.mp4 C:\\out.mp4';self.assertIsNone(self.result(row)[0]['totalFrames'])
    def test_old_contract_unchanged(self):
        self.assertNotIn('processSnapshot',decode(legacy.packet(),[legacy.CONFIG]))
    def test_missing_declared_source_isolated(self):
        value=decode(packet([process()]),[legacy.CONFIG]);self.assertEqual(value['sourceErrors'],['fixture']);self.assertTrue(value['partial']);self.assertTrue(value['processSnapshot']['observations'][0]['qualified'])
    def test_bad_legacy_hash_isolated(self):
        raw=legacy.packet();raw.update(processSchema=1,processPartial=False,observedAt=stamp(),processes=[process()]);raw['runs'][0]['sources'][0]['sha256']='f'*64
        value=decode(raw,[legacy.CONFIG]);self.assertEqual(value['runs'],[]);self.assertEqual(len(value['processSnapshot']['observations']),1);self.assertTrue(value['partial'])
    def test_modern_legacy_claim_needs_verified_process_identity(self):
        raw=legacy.packet();raw.update(processSchema=1,processPartial=False,observedAt=stamp())
        row=process();row['birth']=legacy.NOW
        row['argv']=f'C:\\Apps\\blender.exe -b -P "{legacy.C["paths"]["S"]}" -- --plan A --anim "{legacy.C["paths"]["OUT"]}"'
        raw['processes']=[row]
        value=decode(raw,[legacy.CONFIG]);self.assertEqual(len(value['runs'][0]['claims']),1);self.assertEqual(value['processSnapshot']['observations'],[])
        for key,value in [('ownerVerified',False),('revalidated',False),('executable','')]:
            invalid=copy.deepcopy(raw);invalid['processes'][0][key]=value
            value=decode(invalid,[legacy.CONFIG]);self.assertEqual(value['runs'][0]['claims'],[]);self.assertTrue(value['partial'])
    def test_dedup_legacy_pid_birth(self):
        row=process();self.assertEqual(snapshot(packet([row]),[(row['pid'],row['birth'])])['observations'],[])
    def test_native_gui_f12_no_timeline_total(self):
        row=process(arguments='C:\\Apps\\blender.exe C:\\scene.blend');relay(row);value=self.result(row)[0]
        self.assertTrue(value['qualified']);self.assertIsNone(value['totalFrames']);self.assertEqual(value['currentFrame'],-2);self.assertEqual(value['nativeState'],'active')
    def test_unknown_relay_keeps_independent_cli_evidence(self):
        row=process();relay(row,'unknown');value=self.result(row)[0]
        self.assertTrue(value['qualified']);self.assertEqual(value['evidence'],'render_command');self.assertNotIn('invocationToken',value)
        row=process(arguments='C:\\Apps\\blender.exe');relay(row,'unknown');self.assertFalse(self.result(row)[0]['qualified'])
    def test_native_idle_without_invocation_is_not_a_job(self):
        row=process(arguments='C:\\Apps\\blender.exe')
        event=dict(schemaVersion=1,pid=row['pid'],birthToken=row['birthToken'],state='idle',jobRunning=False,observedAt=stamp(),recentInvocations=[])
        row['blenderRelay']=dict(text=json.dumps(event),modified=stamp())
        value=snapshot(packet([row]));self.assertTrue(value['coverageComplete']);self.assertEqual(value['observations'],[])
        for field,value in [('observedAt',stamp(-16)),('observedAt',stamp(1)),('birthToken','111111111111111111'),('pid',123),('jobRunning',True)]:
            invalid=copy.deepcopy(row);bad=dict(event);bad[field]=value;invalid['blenderRelay']['text']=json.dumps(bad)
            self.assertEqual(len(self.result(invalid)),1);self.assertFalse(self.result(invalid)[0]['qualified'])
        row=process();row['blenderRelay']=dict(text=json.dumps(event),modified=stamp())
        self.assertTrue(self.result(row)[0]['qualified'])
    def test_native_invocation_identity(self):
        row=process(arguments='C:\\Apps\\blender.exe');relay(row,token='a'*32);one=self.result(row)[0]['id'];relay(row,token='b'*32);self.assertNotEqual(one,self.result(row)[0]['id'])
    def test_background_script_loop_is_one_process_task(self):
        row=process();ids=[]
        for token in ['a'*32,'b'*32,'c'*32]:
            relay(row,token=token);value=self.result(row)[0];ids.append(value['id'])
            self.assertTrue(value['qualified']);self.assertEqual(value['evidence'],'render_command');self.assertNotIn('invocationToken',value)
            self.assertTrue(value['backgroundProcess'])
        self.assertEqual(len(set(ids)),1)
    def test_background_native_only_never_finishes_outer_process(self):
        row=process(arguments='C:\\Apps\\blender.exe -b -P C:\\complex.py -- --custom');ids=[]
        for state in ['active','complete','active','cancel']:
            relay(row,state,token=('a' if len(ids)%2 else 'b')*32);value=self.result(row)[0];ids.append(value['id'])
            self.assertNotIn('nativeState',value);self.assertNotIn('invocationToken',value)
            self.assertEqual(value['qualified'],state=='active');self.assertIsNone(value.get('completedSignal'))
        self.assertEqual(len(set(ids)),1)
    def test_fifty_active_gui_before_bounded_terminal_history(self):
        rows=[]
        for pid in range(1,51):
            row=process(pid=pid,arguments='C:\\Apps\\blender.exe');event=relay(row)
            event['recentInvocations']=[]
            for n in range(8):
                old={k:v for k,v in event.items() if k!='recentInvocations'}
                old.update(invocationToken=hex(n+1)[2:]*32,state='complete',phase='complete',jobRunning=False)
                event['recentInvocations'].append(old)
            row['blenderRelay']['text']=json.dumps(event);rows.append(row)
        value=snapshot(packet(rows))
        active=[r for r in value['observations'] if r['qualified'] and r.get('nativeState')=='active']
        self.assertEqual(len(active),50);self.assertLessEqual(len(value['observations']),128);self.assertTrue(value['coverageComplete']);self.assertTrue(value['historyTruncated'])
    def test_native_wrong_birth_pid_stale_and_crash(self):
        for field,value in [('birthToken','111111111111111111'),('pid',500),('observedAt',stamp(-16)),('invocationToken','bad')]:
            row=process(arguments='C:\\Apps\\blender.exe');event=relay(row);event[field]=value;row['blenderRelay']['text']=json.dumps(event)
            self.assertFalse(self.result(row)[0]['qualified'])
        self.assertEqual(snapshot(packet([]))['observations'],[])
    def test_native_complete_cancel_not_count_finish(self):
        for state in ['complete','cancel']:
            row=process(arguments='C:\\Apps\\blender.exe');relay(row,state);value=self.result(row)[0];self.assertEqual(value['nativeState'],state);self.assertIsNone(value['totalFrames']);self.assertIsNone(value.get('completedSignal'))
    def test_template_safety_and_bounds(self):
        value=ps_script([]);self.assertNotIn('__CONFIG__',value);self.assertIn('950000',value);self.assertIn('$row.birthToken',value)
        self.assertNotIn('Start-Process',value);self.assertNotIn('Stop-Process',value)

class RelayTests(unittest.TestCase):
    def result(self,row):return snapshot(packet([row]))['observations']
    def setup_relay(self,root):
        handlers=types.SimpleNamespace(persistent=lambda f:f,**{'render_'+k:[] for k in ['init','pre','post','write','complete','cancel']})
        registrations=[]
        timers=types.SimpleNamespace(register=lambda f,**kw: registrations.append(kw),is_registered=lambda f:False,unregister=lambda f:None,registrations=registrations)
        bpy=types.SimpleNamespace(app=types.SimpleNamespace(handlers=handlers,timers=timers,is_job_running=lambda kind:True))
        relay=Relay(bpy,Path(root).resolve(),42,'133999999999999999',clock=lambda:NOW.timestamp(),monotonic=lambda:100)
        return relay,bpy
    def test_handlers_per_invocation_counts_no_settings(self):
        with tempfile.TemporaryDirectory() as root:
            r,b=self.setup_relay(root);r.register();scene=types.SimpleNamespace(name='Scene',frame_current=0,frame_end=999)
            self.assertTrue(all(len(getattr(b.app.handlers,'render_'+k))==1 for k in ['init','pre','post','write','complete','cancel']))
            self.assertEqual(b.app.timers.registrations,[dict(first_interval=2.0,persistent=True)])
            for kind in ['init','pre','post','post','write','write','complete']:getattr(b.app.handlers,'render_'+kind)[0](scene)
            one=json.loads((Path(root)/'42.json').read_text());self.assertEqual(one['state'],'complete');self.assertEqual(one['completedFrames'],1);self.assertEqual(one['writtenFrames'],1);self.assertEqual(one['currentFrame'],0);self.assertNotIn('totalFrames',one)
            r.event('init',scene);two=json.loads((Path(root)/'42.json').read_text());self.assertNotEqual(one['invocationToken'],two['invocationToken']);self.assertEqual(two['completedFrames'],0)
            r.unregister();self.assertTrue(all(not getattr(b.app.handlers,'render_'+k) for k in ['init','pre','post','write','complete','cancel']));self.assertEqual(r.heartbeat(),None)
            self.assertEqual(list(Path(root).glob('*.tmp')),[])
    def test_registered_idle_heartbeat_is_native_proof_not_fake_invocation(self):
        with tempfile.TemporaryDirectory() as root:
            r,b=self.setup_relay(root);b.app.is_job_running=lambda kind:False;r.register()
            self.assertIsNone(r.state);self.assertEqual(r.heartbeat(),10.0)
            path=Path(root)/'42.json';event=json.loads(path.read_text())
            self.assertEqual(event['state'],'idle');self.assertNotIn('invocationToken',event);self.assertNotIn('startedAt',event)
            row=process(arguments='C:\\Apps\\blender.exe');row['blenderRelay']=dict(text=path.read_text(),modified=stamp())
            self.assertEqual(self.result(row),[])
            b.app.is_job_running=lambda kind:True;self.assertEqual(r.heartbeat(),2.0)
            row['blenderRelay']['text']=path.read_text();self.assertEqual(len(self.result(row)),1)
            b.app.is_job_running=lambda kind:False;r.heartbeat();r.unregister()
            self.assertEqual(json.loads(path.read_text())['state'],'unknown');self.assertEqual(r.heartbeat(),None)
    def test_two_short_f12_before_poll_survive_decode_and_bounded_ring(self):
        with tempfile.TemporaryDirectory() as root:
            r,b=self.setup_relay(root);scene=types.SimpleNamespace(name='Scene',frame_current=1)
            r.register()
            for _ in range(2):
                for event in ['init','pre','post','complete']:r.event(event,scene)
            path=Path(root)/'42.json';data=json.loads(path.read_text())
            self.assertEqual(len(data['recentInvocations']),1)
            row=process(arguments='C:\\Apps\\blender.exe');row['blenderRelay']=dict(text=path.read_text(),modified=stamp())
            values=self.result(row)
            self.assertEqual(len(values),2);self.assertEqual(len({v['invocationToken'] for v in values}),2)
            self.assertTrue(all(v['nativeState']=='complete' for v in values))
            for _ in range(20):
                for event in ['init','pre','post','complete']:r.event(event,scene)
            data=json.loads(path.read_text());self.assertLessEqual(len(data['recentInvocations']),8);self.assertLessEqual(path.stat().st_size,8192)
            r.unregister()
    def test_title_filename_and_scene_without_directories(self):
        with tempfile.TemporaryDirectory() as root:
            r,b=self.setup_relay(root);scene=types.SimpleNamespace(name='Scene',frame_current=1)
            b.data=types.SimpleNamespace(filepath=r'C:\Clients\Private\SampleScene.blend')
            r.event('init',scene);first=r.state['title']
            b.data.filepath=r'C:\Clients\Private\Coffre.blend'
            r.event('init',scene);second=r.state['title']
            self.assertEqual(first,'SampleScene.blend · Scene');self.assertEqual(second,'Coffre.blend · Scene')
            self.assertNotEqual(first,second);self.assertNotIn('Private',first);self.assertNotIn('Clients',second)
            b.data.filepath='/private/client/SampleScene.blend';r.event('init',scene);self.assertEqual(r.state['title'],first)
            b.data.filepath='';r.event('init',scene);self.assertEqual(r.state['title'],'Scene')
            del b.data;r.event('init',scene);self.assertEqual(r.state['title'],'Scene')
    def test_register_does_not_access_scene_data_and_title_failure_is_safe(self):
        with tempfile.TemporaryDirectory() as root:
            r,b=self.setup_relay(root)
            class Restricted:
                app=b.app
                @property
                def data(self):raise RuntimeError('RestrictBlend')
                @property
                def context(self):raise RuntimeError('RestrictBlend')
            r.bpy=Restricted();r.register();self.assertTrue(r.enabled);self.assertEqual(len(r.callbacks),6)
            r.event('init',types.SimpleNamespace(name='Scene',frame_current=0));self.assertEqual(r.state['title'],'Scene')
            r.unregister()
    def test_heartbeat_missing_end_unknown_cancel_distinct(self):
        with tempfile.TemporaryDirectory() as root:
            r,b=self.setup_relay(root);r.register();scene=types.SimpleNamespace(name='x',frame_current=-5);r.event('init',scene)
            self.assertEqual(r.heartbeat(),2.0);self.assertEqual(r.state['state'],'active')
            b.app.is_job_running=lambda kind:False;r.heartbeat();self.assertEqual(r.state['state'],'unknown')
            r.event('cancel',scene);r.heartbeat();self.assertEqual(r.state['state'],'cancel');r.unregister()
    def test_io_failure_never_escapes_to_blender(self):
        with tempfile.TemporaryDirectory() as root:
            invalid=Path(root)/'file';invalid.write_text('x');r,b=self.setup_relay(invalid/'child');r.register()
            for kind in ['init','pre','post','write','complete']:r.event(kind,types.SimpleNamespace(name='x',frame_current=1))
            self.assertEqual(r.heartbeat(),10.0);r.unregister()

if __name__=='__main__':unittest.main()
