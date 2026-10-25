import datetime, hashlib, importlib.util, json, os, sys, tempfile, types, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
I=ROOT/'Sources/RenduBar/Infrastructure';sys.path.insert(0,str(I))
import render_library_transport as library
from blender_render_relay import Relay, OutputManifest

class TransportTests(unittest.TestCase):
    def request(self,path):
        now=datetime.datetime.now(datetime.timezone.utc)
        return dict(operation='stage',activatedAt=(now-datetime.timedelta(minutes=2)).isoformat(),localFile=str(path),artifact=dict(connectionScope=hashlib.sha256(b'host|user').hexdigest(),path='C:/out/final.png',processID=42,birthToken='133999999999999999',invocationToken='a'*32,startedAt=(now-datetime.timedelta(minutes=1)).isoformat(),completedAt=(now-datetime.timedelta(seconds=20)).isoformat()))
    def test_activation_connection_source_type_guards(self):
        r=self.request('/private/tmp/fixture.png');library.validate(r,'host','user')
        for change in [dict(connectionScope='0'*64),dict(path='C:/project.blend'),dict(path='C:/out/../private.png'),dict(processID=True)]:
            bad=dict(r,artifact=dict(r['artifact'],**change))
            with self.assertRaises(ValueError):library.validate(bad,'host','user')
        bad=dict(r,activatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
        with self.assertRaises(ValueError):library.validate(bad,'host','user')
    def test_copy_stable_and_source_never_removed_by_stage(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d).resolve()/'copy.png';r=self.request(path);data=b'test-final-pixel';sha=hashlib.sha256(data).hexdigest();calls=[]
            def probe(r,e):calls.append(r['operation']);return dict(ok=True,sha256=sha,bytes=len(data),identity='same-file')
            def download(r,e,p,n):p.write_bytes(data)
            result=library.stage(r,[],remote=probe,download=download,pause=lambda n:None)
            self.assertEqual(path.read_bytes(),data);self.assertEqual(result['sha256'],sha);self.assertEqual(calls,['inspect','inspect']);self.assertEqual(list(path.parent.glob('*.partial')),[])
    def test_changed_remote_and_collision_never_report_success(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d).resolve()/'copy.png';r=self.request(path);data=b'pixel';sha=hashlib.sha256(data).hexdigest();calls=[]
            def probe(r,e):calls.append(1);return dict(ok=True,sha256=sha,bytes=len(data),identity=str(len(calls)))
            with self.assertRaises(ValueError):library.stage(r,[],remote=probe,download=lambda r,e,p,n:p.write_bytes(data),pause=lambda n:None)
            path.write_bytes(b'other');calls.clear()
            with self.assertRaises(ValueError):library.stage(r,[],remote=probe,download=lambda *a:self.fail('download on collision'),pause=lambda n:None)
            self.assertEqual(path.read_bytes(),b'other')
    def test_failed_download_cleans_only_its_partial(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d).resolve()/'copy.png';unrelated=path.parent/'unrelated.partial';unrelated.write_text('keep');r=self.request(path)
            def download(r,e,p,n):p.write_bytes(b'partial');raise RuntimeError('interrupted')
            with self.assertRaises(RuntimeError):library.stage(r,[],remote=lambda *a:dict(ok=True,sha256='a'*64,bytes=123,identity='one'),download=download,pause=lambda n:None)
            self.assertEqual(list(path.parent.iterdir()),[unrelated])
    def test_reparse_and_wrong_export_hash_refused(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d).resolve();target=base/'target';target.mkdir();link=base/'alias';link.symlink_to(target,True)
            with self.assertRaises(ValueError):library.safe_local(link/'copy.png')
            r=self.request(base/'copy.png');r['artifact']['expectedSHA256']='b'*64
            with self.assertRaises(ValueError):library.stage(r,[],remote=lambda *a:dict(ok=True,sha256='a'*64,bytes=1,identity='one'),download=lambda *a:self.fail('wrong hash downloaded'),pause=lambda n:None)
    def test_script_contract_has_handle_rename_and_no_delete_of_source(self):
        script=(I/'remote_library.ps1').read_text();command,payload=library.invocation(self.request('/private/tmp/output.png'))
        self.assertIn('SetFileInformationByHandle',script);self.assertIn('Replace;public IntPtr Root',script);self.assertIn('2147483648',script)
        self.assertIn('other-producer-present',script);self.assertIn('activation-barrier',script)
        self.assertNotIn('Remove-Item',script);self.assertNotIn('Start-Process',script);self.assertNotIn('Stop-Process',script)
        self.assertLess(len(command),2000);self.assertTrue(payload.endswith(b'\n'))

class ManifestTests(unittest.TestCase):
    def test_65_outputs_have_three_pages_and_rerender_identity(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();output=root/'outputs';output.mkdir();state=dict(invocationToken='a'*32,pid=42,birthToken='133999999999999999',startedAt='2026-10-24T12:00:00Z',eventAt='2026-10-24T12:01:00Z')
            manifest=OutputManifest(root/'Manifests',state)
            for n in range(65):
                file=output/('f_%04d.png'%n);file.write_bytes(b'pixel');manifest.append(str(file),n)
            proof=manifest.finish();self.assertTrue(proof['complete']);self.assertEqual(proof['expectedCount'],65)
            index=json.loads(Path(proof['indexPath']).read_text());self.assertEqual([p['count'] for p in index['pages']],[32,32,1])
            first=json.loads((Path(proof['indexPath']).parent/index['pages'][0]['name']).read_text())['artifacts'][0]
            again=OutputManifest(root/'Manifests',dict(state,invocationToken='b'*32));again.append(str(output/'f_0000.png'),0);other=again.finish()
            second=json.loads((Path(other['indexPath']).parent/'final-000000.json').read_text())['artifacts'][0]
            self.assertNotEqual(first['id'],second['id']);self.assertEqual(first['bytes'],5);self.assertEqual(len(list(output.iterdir())),65)

class ExportTests(unittest.TestCase):
    DATA=b'final-image-fixture'
    def make(self,d,optin=True,fmt='PNG'):
        root=Path(d).resolve()/'Blender';root.mkdir()
        active=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=1)).isoformat()
        if optin:(root.parent/'LibraryPolicy.json').write_text(json.dumps(dict(schemaVersion=1,enabled=True,exportInMemory=True,activatedAt=active,expiresAt=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=120)).isoformat())))
        class Image:
            has_data=True;type='RENDER_RESULT';filepath_raw='';size=[1,1];channels=4;render_slots=types.SimpleNamespace(active_index=0)
            def as_pointer(self):return 900
            def save_render(self,path,scene):Path(path).write_bytes(ExportTests.DATA)
        image=Image();render=types.SimpleNamespace(filepath='C:/untouched',image_settings=types.SimpleNamespace(file_format=fmt),use_multiview=False)
        scene=types.SimpleNamespace(name='Scene',frame_current=1,render=render,as_pointer=lambda:700)
        bpy=types.SimpleNamespace(app=types.SimpleNamespace(background=False,is_job_running=lambda _:False),data=types.SimpleNamespace(filepath='C:/project_v50.blend',images={'Render Result':image}))
        relay=Relay(bpy,root,42,'133999999999999999');relay.enabled=True
        return relay,bpy,scene,image
    def complete(self,r,s):
        for event in ['init','pre','post','complete']:r.event(event,s)
        r.heartbeat()
    def test_optin_export_no_settings_or_source_mutations(self):
        with tempfile.TemporaryDirectory() as d:
            r,b,s,image=self.make(d);before=(b.data.filepath,s.render.filepath,s.render.image_settings.file_format,image.filepath_raw)
            self.complete(r,s);self.assertEqual(r.state['exportState'],'exported');self.assertTrue(r.state['outputManifest']['complete']);a=r.state['exportArtifact']
            self.assertEqual(Path(a['path']).read_bytes(),self.DATA);self.assertEqual(a['sha256'],hashlib.sha256(self.DATA).hexdigest())
            self.assertEqual(before,(b.data.filepath,s.render.filepath,s.render.image_settings.file_format,image.filepath_raw));self.assertEqual(r.state['writtenFrames'],0)
    def test_no_optin_or_unsupported_format_stays_memory(self):
        for optin,fmt in [(False,'PNG'),(True,'FFMPEG')]:
            with tempfile.TemporaryDirectory() as d:
                r,b,s,image=self.make(d,optin,fmt);self.complete(r,s);self.assertNotIn('exportArtifact',r.state);self.assertFalse((r.root.parent/'Outbox').exists())
    def test_changed_frame_slot_or_removed_policy_refused(self):
        for change in ['frame','slot','policy']:
            with tempfile.TemporaryDirectory() as d:
                r,b,s,image=self.make(d)
                for event in ['init','pre','post','complete']:r.event(event,s)
                if change=='frame':s.frame_current=2
                elif change=='slot':image.render_slots.active_index=1
                else:(r.root.parent/'LibraryPolicy.json').unlink()
                r.heartbeat();self.assertEqual(r.state['exportState'],'inMemoryNeedsReview');self.assertNotIn('exportArtifact',r.state)
    def test_expired_policy_cannot_export(self):
        with tempfile.TemporaryDirectory() as d:
            r,b,s,image=self.make(d);file=r.root.parent/'LibraryPolicy.json';p=json.loads(file.read_text());p['expiresAt']=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=1)).isoformat();file.write_text(json.dumps(p));self.complete(r,s);self.assertNotIn('exportArtifact',r.state)

    def test_second_render_before_export_never_exports_old_result(self):
        with tempfile.TemporaryDirectory() as d:
            r,b,s,image=self.make(d)
            for event in ['init','pre','post','complete']:r.event(event,s)
            old=r.state['invocationToken'];r.event('init',s);r.heartbeat()
            self.assertEqual(r.recent_invocations[0]['exportState'],'inMemoryReplacedBeforeExport');self.assertNotEqual(old,r.state['invocationToken']);self.assertNotIn('exportArtifact',r.state)

if __name__=='__main__':unittest.main()
