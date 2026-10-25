#!/usr/bin/env python3
"""Headless Sparkle checks only. Stops before downloads/preparation; real installation is a human UI gate."""
from pathlib import Path
import base64,functools,hashlib,http.server,importlib.util,json,os,platform,plistlib,signal,stat,subprocess,sys,tempfile,threading,time,uuid,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('AUTORENDER_UPDATE_TEST_OUTPUT','/private/tmp/autoren-update-test-evidence'));OUT.mkdir(parents=True,exist_ok=True)
GROUPS=[];RUNS=[];FIXTURE_IDS=[]
signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(SystemExit(143)))
def group_rows(group):
 rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,stat=,command='],text=True).splitlines()
 return [r.strip() for r in rows if len(r.split(None,4))==5 and int(r.split(None,4)[2])==group]
def run(args,timeout=180):
 p=subprocess.Popen([str(a) for a in args],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);GROUPS.append(p.pid)
 try:out,err=p.communicate(timeout=timeout)
 finally:
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.communicate(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.communicate()
 RUNS.append({'command':[str(a) for a in args],'exit':p.returncode,'stdout':out,'stderr':err})
 return p.returncode,out,err
def must(args,timeout=180):
 code,out,err=run(args,timeout);assert code==0,err;return out.strip()
def fixture_preference_paths(identifier):
 require_prefix='fr.robtech.autorender.headlessfixture.'
 assert identifier.startswith(require_prefix) and len(identifier.removeprefix(require_prefix))==32
 assert all(c in '0123456789abcdef' for c in identifier.removeprefix(require_prefix))
 library=Path.home()/'Library/Preferences'
 return [library/(identifier+'.plist'),*sorted((library/'ByHost').glob(identifier+'.*.plist'))]
def cleanup_fixture_preferences(identifier):
 removed=[];observed=[]
 for path in fixture_preference_paths(identifier):
  observed.append(str(path));finished=False
  # CFPreferences may finish the client's removal shortly after that process exits.
  # Wait at most five seconds for an empty state; never clear/delete a nonempty file.
  for attempt in range(50):
   if not os.path.lexists(path):finished=True;break
   try:before=path.lstat()
   except FileNotFoundError:finished=True;break
   assert stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and not path.is_symlink() and before.st_size<=1024*1024,'Unexpected fixture preferences ownership/type/size'
   try:descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
   except FileNotFoundError:finished=True;break
   try:
    opened=os.fstat(descriptor)
    if (opened.st_dev,opened.st_ino)!=(before.st_dev,before.st_ino):time.sleep(.1);continue
    with os.fdopen(descriptor,'rb',closefd=False) as stream:raw=stream.read()
    if raw and plistlib.loads(raw)!={}:time.sleep(.1);continue
    try:current=path.lstat()
    except FileNotFoundError:finished=True;break
    if (current.st_dev,current.st_ino,current.st_uid)!=(before.st_dev,before.st_ino,os.getuid()) or path.read_bytes()!=raw:time.sleep(.1);continue
    path.unlink();removed.append({'path':str(path),'sha256':hashlib.sha256(raw).hexdigest(),'empty_dictionary':True});finished=True;break
   finally:os.close(descriptor)
  assert finished,'Nonempty fixture preferences preserved after bounded flush wait'
 remaining=[str(path) for path in fixture_preference_paths(identifier) if os.path.lexists(path)]
 assert not remaining,'Fixture preferences physically remain'
 return {'bundle_id':identifier,'suite':identifier,'checked_paths':observed,'removed_empty_files':removed,'remaining':remaining,'physical_absence_verified':True}
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def files(root):return {str(p.relative_to(root)):digest(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}
protected_roots=[(Path.home()/'Applications/AUTORENDER.app'),ROOT/'Build/Products.noindex/AUTORENDER-0.7.1.app',(Path.home()/'Library/Application Support/RenduBar')]
candidate080=ROOT/'Build/Products.noindex/AUTORENDER-0.8.0.app'
if candidate080.exists():protected_roots.append(candidate080)
before={str(p):files(p) for p in protected_roots};results={};status='HOLD';server=None;thread=None;temporary=None
support=(Path.home()/'Library/Application Support/RenduBar');prefs=(Path.home()/'Library/Preferences/fr.robtech.rendubar.plist')
registry=support/'monitor-jobs.json';registry_before=(os.readlink(registry),digest(registry));prefs_before=digest(prefs)
try:
 sparkle=Path(must(['python3','-B',ROOT/'Scripts/sparkle-dependency.py']));signer=sparkle/'bin/sign_update'
 with tempfile.TemporaryDirectory(prefix='autorender-updater-fixture-') as temp:
  temporary=Path(temp);os.chmod(temporary,0o700);exe=temporary/'headless-tests'
  must(['/usr/bin/swiftc','-target',platform.machine()+'-apple-macosx14.0','-parse-as-library','-framework','AppKit','-framework','Security','-F',sparkle,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',sparkle,ROOT/'Sources/RenduBar/Domain/SoftwareUpdatePolicy.swift',ROOT/'Sources/RenduBar/App/SoftwareUpdateCoordinator.swift',ROOT/'Tests/SoftwareUpdateHeadlessTests.swift','-o',exe])
  results['driver_guards_simulated']=must([exe,'guards'])
  if '--termination-only' in sys.argv:
   identifier='fr.robtech.autorender.headlessfixture.'+uuid.uuid4().hex
   assert not any(os.path.lexists(path) for path in fixture_preference_paths(identifier));FIXTURE_IDS.append(identifier)
   app=temporary/'termination.app';(app/'Contents/MacOS').mkdir(parents=True)
   (app/'Contents/MacOS/Fixture').write_bytes(b'#!/bin/sh\nexit 0\n');(app/'Contents/MacOS/Fixture').chmod(0o755)
   info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'Fixture','CFBundleName':'AUTORENDER termination fixture','CFBundlePackageType':'APPL','CFBundleVersion':'100','CFBundleShortVersionString':'100','SUEnableAutomaticChecks':False,'SUAllowsAutomaticUpdates':False,'SUAutomaticallyUpdate':False}
   (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
   results['termination_callbacks']=must([exe,'termination',app])
  else:
   key=temporary/'ephemeral-seed';public=must([exe,'key',key]);assert len(base64.b64decode(public))==32
   webroot=temporary/'web';webroot.mkdir();requests=[]
   class Handler(http.server.SimpleHTTPRequestHandler):
    timeout=5
    def log_message(self,*args):pass
    def end_headers(self):self.send_header('Cache-Control','no-store');super().end_headers()
    def do_GET(self):requests.append(self.path);return super().do_GET()
   server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=webroot));server.daemon_threads=False
   thread=threading.Thread(target=server.serve_forever,name='autorender-fixture-loopback');thread.start();url='http://127.0.0.1:'+str(server.server_address[1]);identifier='fr.robtech.autorender.headlessfixture.'+uuid.uuid4().hex;assert not any(os.path.lexists(path) for path in fixture_preference_paths(identifier));FIXTURE_IDS.append(identifier)
   apps=[]
   for version in ['100','101']:
    app=temporary/('fixture-'+version+'.app');(app/'Contents/MacOS').mkdir(parents=True)
    # These fixture bundles are never launched or registered; only metadata and archive bytes are used.
    (app/'Contents/MacOS/Fixture').write_bytes(b'#!/bin/sh\nexit 0\n');(app/'Contents/MacOS/Fixture').chmod(0o755)
    info={'CFBundleIdentifier':identifier,'CFBundleExecutable':'Fixture','CFBundleName':'AUTORENDER isolated test','CFBundlePackageType':'APPL','CFBundleVersion':version,'CFBundleShortVersionString':version,'SUPublicEDKey':public,'SUFeedURL':url+'/appcast.xml','SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'SUSignedFeedFailureExpirationInterval':0,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True}}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info));must(['/usr/bin/codesign','--force','--sign','-',app]);apps.append(app)
   results['termination_callbacks']=must([exe,'termination',apps[0]])
   # Import only the pure input guards. The production release entrypoint is not executed.
   spec=importlib.util.spec_from_file_location('autorender_release_inputs',ROOT/'Scripts/prepare-update-release.py');release=importlib.util.module_from_spec(spec);spec.loader.exec_module(release)
   notes=temporary/'notes.md';notes.write_bytes(b'Public release notes only.');release_output=temporary/'release-output';security_checks=0
   captured,_=release.inspect_private_inputs(apps[0],notes,key,release_output);assert captured==notes.read_bytes();security_checks+=1
   def rejected(label,app,notefile,keyfile):
    try:release.inspect_private_inputs(app,notefile,keyfile,release_output)
    except (release.ReleaseInputError,ValueError):return
    raise AssertionError('Secret input guard did not reject '+label)
   rejected('same-file',apps[0],key,key);security_checks+=1
   alias=temporary/'seed-hardlink.md';os.link(key,alias);rejected('hardlink-notes',apps[0],alias,key);security_checks+=1;alias.unlink()
   alias=temporary/'seed-symlink.md';alias.symlink_to(key);rejected('symlink-notes',apps[0],alias,key);security_checks+=1;alias.unlink()
   notes.write_bytes(b'Accidental signing content: '+key.read_bytes());rejected('key-in-notes',apps[0],notes,key);security_checks+=1
   notes.write_bytes(base64.b64decode(key.read_bytes()));rejected('raw-seed-in-notes',apps[0],notes,key);security_checks+=1
   notes.write_bytes(b'Public release notes only.')
   embedded=apps[0]/'Contents/private.md';embedded.write_bytes(key.read_bytes());embedded.chmod(0o600)
   try:
    rejected('key-inside-bundle',apps[0],notes,embedded);security_checks+=1
    rejected('key-content-in-bundle',apps[0],notes,key);security_checks+=1
   finally:embedded.unlink()
   embedded=apps[0]/'Contents/private-alias';os.link(key,embedded)
   try:rejected('hardlink-in-bundle',apps[0],notes,key);security_checks+=1
   finally:embedded.unlink()
   keytool=temporary/'key-check';must(['/usr/bin/swiftc','-target',platform.machine()+'-apple-macosx14.0',ROOT/'Scripts/UpdateSigningKey.swift','-o',keytool])
   assert must([keytool,key,public])=='PUBLIC_KEY_MATCH';security_checks+=1
   other_public=must([exe,'key',temporary/'different-seed']);assert run([keytool,key,other_public])[0]!=0;security_checks+=1
   assert not release_output.exists();security_checks+=1
   results['release_secret_guards_and_cryptokit']={'assertions':security_checks,'key_match':True,'wrong_public_key_refused':True,'private_material_in_output':False}
   a_before=files(apps[0]);archive=webroot/'update.zip';must(['/usr/bin/ditto','-c','-k','--keepParent',apps[1],archive]);signature=must([signer,'--ed-key-file',key,'-p',archive]);assert len(base64.b64decode(signature))==64
   must([signer,'--verify','--ed-key-file',key,archive,signature]);results['official_archive_signature']='PASS'
   invalid=base64.b64encode(b'\0'*64).decode();assert run([signer,'--verify','--ed-key-file',key,archive,invalid])[0]!=0;results['official_bad_signature_rejected']=True
   corrupted=temporary/'corrupted.zip';corrupted.write_bytes(archive.read_bytes()+b'corrupted');assert run([signer,'--verify','--ed-key-file',key,corrupted,signature])[0]!=0;results['official_corruption_rejected']=True
   generated_notes=webroot/'update.md';generated_notes.write_text('Isolated public release notes.\n')
   must([sparkle/'bin/generate_appcast','--ed-key-file',key,'--download-url-prefix',url+'/','--release-notes-url-prefix',url+'/','--maximum-deltas','0','-o',webroot/'appcast.xml',webroot])
   must([signer,'--verify','--ed-key-file',key,webroot/'appcast.xml'])
   generated=ET.parse(webroot/'appcast.xml');namespace='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
   note=generated.find('channel/item/'+namespace+'releaseNotesLink');assert note is not None
   must([signer,'--verify','--ed-key-file',key,generated_notes,note.attrib[namespace+'edSignature']])
   generated_result=json.loads(must([exe,'probe_retry',apps[0]],timeout=75).splitlines()[-1]);assert generated_result['found']=='101' and generated_result['manual_retry_found']=='101'
   results['official_generate_appcast_signed_feed_and_notes']={'signatures_verified':True,'sparkle_selection_and_manual_retry':generated_result}
   for name,version,extra in [('valid','101',''),('downgrade','99',''),('descending_display','105','<sparkle:shortVersionString>99</sparkle:shortVersionString>'),('invalid_display','105','<sparkle:shortVersionString>unknown</sparkle:shortVersionString>'),('unsupported_os','101','<sparkle:minimumSystemVersion>99.0.0</sparkle:minimumSystemVersion>'),('tampered_feed','101',''),('unsigned_feed','101','')]:
    feed=webroot/'appcast.xml';feed.write_text(f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated fixture</title><item><title>Fixture {version}</title><sparkle:version>{version}</sparkle:version>{extra}<description>Isolated fixture release notes</description><enclosure url="{url}/update.zip" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}" /></item></channel></rss>''')
    if name!='unsigned_feed':must([signer,'--ed-key-file',key,feed])
    if name=='tampered_feed':feed.write_bytes(feed.read_bytes().replace(b'Isolated fixture',b'Tampered fixture'))
    output=must([exe,'probe_retry' if name=='valid' else 'probe',apps[0]],timeout=75);parsed=json.loads(output.splitlines()[-1]);results['sparkle_appcast_'+name]=parsed
    assert (parsed['found']=='101') if name=='valid' else parsed['found'] is None
    assert not any('/update.zip' in request for request in requests),'Unexpected archive download'
    assert files(apps[0])==a_before,'Fixture host changed before installer gate'
   reference_path=os.environ.get('AUTORENDER_UPDATE_CONTRACT_REFERENCE')
   if reference_path:
    reference=Path(reference_path).resolve();reference_before=digest(reference);reference_copy=temporary/'reference-update-contract.mjs';reference_copy.write_bytes(reference.read_bytes())
    # Offline reserved test URL only; it is never configured in any application or contacted.
    fixture_artifact_url='https://fixture.invalid/interop.zip';host='fixture.invalid'
    interop=temporary/'interop';interop.mkdir();interop_archive=interop/'interop.zip'
    fixture_info=plistlib.loads((apps[1]/'Contents/Info.plist').read_bytes());fixture_info['CFBundleIdentifier']='fr.robtech.rendubar';(apps[1]/'Contents/Info.plist').write_bytes(plistlib.dumps(fixture_info));must(['/usr/bin/codesign','--force','--sign','-',apps[1]])
    must(['/usr/bin/ditto','-c','-k','--keepParent',apps[1],interop_archive])
    def official(command,capture=False):
     output=must(command)
     return output if capture else None
    release.write_common_release(interop,interop_archive,fixture_artifact_url,'101','101',platform.machine(),'stable',public,signer,key,official,[host])
    public_file=temporary/'trusted-public.bin';public_file.write_bytes(base64.b64decode(public))
    parsed=json.loads(must(['node',ROOT/'Tests/UpdateContractInterop.mjs',reference_copy,interop/'release.json',interop/'release.json.ed25519',interop_archive,public_file,host]).splitlines()[-1]);assert parsed['status']=='REFERENCE_INTEROP_PASS';assert digest(reference)==reference_before
    results['common_contract_interop']={**parsed,'reference_source':str(reference),'reference_sha256':reference_before,'runtime_dependency':False}
   else:results['common_contract_interop']='NOT_RUN: explicit reference validator path required'
   server.shutdown();server.server_close();thread.join(timeout=5);assert not thread.is_alive();server=None;thread=None
  # Private seed and both fixture bundles disappear through TemporaryDirectory's normal cleanup.
 results['ephemeral_fixture_tree_absent']=not temporary.exists();assert not temporary.exists()
 results['protected_roots_unchanged']={str(p):files(p)==before[str(p)] for p in protected_roots};assert all(results['protected_roots_unchanged'].values())
 results['real_installation']='NOT_RUN_HUMAN_UI_HOLD: Sparkle launcher submits Updater.app progress helper'
 results['real_installation_cancel_busy_quit_retry']='NOT_PROVEN_ENGINE_GATE; simulated driver checks only'
 results['binary_architecture_rejection']='NOT_PROVEN; requires real installer validation on mismatched executable'
 status='TERMINATION_DELTA_PASS_SIMULATED_NO_ENGINE' if '--termination-only' in sys.argv else 'HEADLESS_SCOPED_PASS_REAL_INSTALLER_GATED'
finally:
 if server:server.shutdown();server.server_close()
 if thread:thread.join(timeout=5)
 remaining={str(g):group_rows(g) for g in GROUPS};remaining={k:v for k,v in remaining.items() if v}
 preference_cleanup=[];preference_errors=[]
 for identifier in FIXTURE_IDS:
  try:preference_cleanup.append(cleanup_fixture_preferences(identifier))
  except Exception as error:preference_errors.append({'suite':identifier,'error_type':type(error).__name__,'reason':str(error)})
 time.sleep(0.1)
 preferences_absent=all(not os.path.lexists(path) for identifier in FIXTURE_IDS for path in fixture_preference_paths(identifier))
 results['fixture_preferences']={'bundle_ids':FIXTURE_IDS,'suites':FIXTURE_IDS,'cleanup':preference_cleanup,'errors':preference_errors,'physical_absence_rechecked':preferences_absent}
 tree_absent=temporary is None or not temporary.exists()
 keys_absent=temporary is None or all(not (temporary/name).exists() for name in ['ephemeral-seed','different-seed'])
 results['ephemeral_fixture_tree_absent']=tree_absent
 if preference_errors or not preferences_absent or not tree_absent or not keys_absent:status='HOLD_FIXTURE_CLEANUP'
 results['protected_roots_unchanged']={str(p):files(p)==before[str(p)] for p in protected_roots}
 results['preferences_registry_unchanged']=digest(prefs)==prefs_before and (os.readlink(registry),digest(registry))==registry_before
 receipt={'status':status,'results':results,'runs':RUNS,'process_groups':GROUPS,'remaining_owned_groups':remaining,'loopback_thread_remaining':bool(thread and thread.is_alive()),'private_key_persisted':not keys_absent,'ui_calls':0,'fixture_apps_launched':0,'intentionally_left_running':[]}
 (OUT/'HEADLESS_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({k:v for k,v in receipt.items() if k!='runs'}))
 if status=='HOLD_FIXTURE_CLEANUP':raise RuntimeError('Fixture cleanup held; see exact receipt')
