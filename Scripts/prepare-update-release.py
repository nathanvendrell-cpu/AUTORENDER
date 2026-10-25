#!/usr/bin/env python3
"""Prepare one signed release offline. Never uploads, installs, creates keys or uses Keychain."""
from pathlib import Path
import argparse,base64,ctypes,hashlib,json,os,platform,plistlib,re,signal,stat,subprocess,tempfile,urllib.parse,zipfile,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
class ReleaseInputError(ValueError):pass
def require(ok,reason):
 if not ok:raise ReleaseInputError(reason)
def contains_secret(stream,patterns):
 tail=b'';overlap=max(map(len,patterns))-1
 while True:
  block=stream.read(1024*1024)
  if not block:return False
  data=tail+block
  if any(pattern in data for pattern in patterns):return True
  tail=data[-overlap:] if overlap else b''
def inspect_private_inputs(app,notes,key,destination,project_root=ROOT):
 app=app.resolve();notes=notes.resolve();key=key.resolve();destination=destination.resolve()
 require(key.is_file() and not key.is_relative_to(project_root) and not key.is_relative_to(destination),'Private key must remain outside repository and output')
 require(not key.is_relative_to(app),'Private key inside application bundle')
 st=key.stat();require(st.st_uid==os.getuid() and stat.S_IMODE(st.st_mode)&0o077==0,'Private key owner-only permissions required')
 require(notes.is_file() and not os.path.samefile(notes,key),'Notes alias the private key')
 require(notes.stat().st_size<=1024*1024 and notes.suffix.lower() in ('.md','.html'),'Bounded release notes file required')
 payload=key.read_bytes();seed=base64.b64decode(payload.strip(),validate=True);require(len(seed)==32,'Explicit Sparkle Ed25519 seed format required')
 patterns=tuple(set([payload, payload.strip(),seed,base64.b64encode(seed)]))
 note_data=notes.read_bytes();require(not any(pattern in note_data for pattern in patterns),'Private key content in release notes')
 for item in app.rglob('*'):
  if not item.is_file():continue
  require(not os.path.samefile(item,key),'Private key alias inside application bundle')
  with item.open('rb') as stream:require(not contains_secret(stream,patterns),'Private key content inside application bundle')
 return note_data,patterns

def https_url(value,allowed_hosts):
 u=urllib.parse.urlsplit(value)
 require(isinstance(value,str) and u.scheme=='https' and u.hostname and not u.username and not u.password and not u.query and not u.fragment and u.port in (None,443),'Exact HTTPS URL without credentials/query required')
 require(isinstance(allowed_hosts,list) and allowed_hosts and u.hostname in allowed_hosts,'URL host is not in explicit publisher configuration')
 return u

def write_common_release(stage,archive,artifact_url,version,build,architectures,channel,public_key,signer,key,run,allowed_hosts):
 """Export exactly 7agency.app-update.v1; trust key/hosts are supplied outside the JSON."""
 https_url(artifact_url,allowed_hosts)
 require(all(isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+_-]{0,79}',value) is not None for value in (version,build)),'Version/build outside common contract bound')
 require(0<archive.stat().st_size<=2**53-1,'Exact positive archive size required')
 require(channel in ('stable','prerelease'),'Unsupported release channel')
 archset=set(architectures.split(','))
 require(archset in ({'arm64'},{'x86_64'},{'arm64','x86_64'}),'Validated macOS architecture required')
 architecture='universal2' if len(archset)==2 else next(iter(archset))
 raw_public=base64.b64decode(public_key,validate=True)
 require(len(raw_public)==32 and base64.b64encode(raw_public).decode()==public_key,'Canonical trusted public key required')
 def signature_for(path):
  value=run([str(signer),'--ed-key-file',str(key),'-p',str(path)],capture=True)
  raw=base64.b64decode(value,validate=True)
  require(len(raw)==64 and base64.b64encode(raw).decode()==value,'Noncanonical official signature output')
  run([str(signer),'--verify','--ed-key-file',str(key),str(path),value])
  return value
 archive_signature=signature_for(archive)
 metadata={'schemaVersion':'7agency.app-update.v1','productID':'fr.robtech.rendubar','version':version,'build':build,'platform':'macos','architecture':architecture,'channel':channel,'artifact':{'url':artifact_url,'sizeBytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'signature':{'algorithm':'ed25519','value':archive_signature,'publicKeyID':hashlib.sha256(raw_public).hexdigest()}}}
 data=(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n').encode('utf-8');require(len(data)<=131072,'Release metadata exceeds shared contract bound')
 release=stage/'release.json';release.write_bytes(data)
 (stage/'release.json.ed25519').write_text(signature_for(release)+'\n',encoding='ascii')
 return metadata

def main():
 p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--notes',type=Path,required=True);p.add_argument('--feed-url',required=True);p.add_argument('--download-base-url',required=True);p.add_argument('--notes-base-url',required=True);p.add_argument('--ed-key-file',type=Path,required=True);p.add_argument('--architectures',required=True);p.add_argument('--artifact-url',required=True);p.add_argument('--allowed-host',action='append',required=True);p.add_argument('--channel',choices=['stable','prerelease'],default='stable');p.add_argument('--max-archive-bytes',type=int,required=True);args=p.parse_args()
 app=args.app.resolve();dest=args.output.resolve();key=args.ed_key_file.resolve();notes=args.notes.resolve()
 require(0<args.max_archive_bytes<=2**53-1,'Explicit positive archive size bound required')
 feed=https_url(args.feed_url,args.allowed_host)
 for value in (args.download_base_url,args.notes_base_url,args.artifact_url):https_url(value,args.allowed_host)
 require(not app.is_relative_to(Path.home()/'Applications') and not app.is_relative_to(Path('/Applications')),'Use a release artifact, never an installed user bundle')
 require(not dest.exists() and not dest.is_relative_to(app),'Fresh separate output required')
 require(not args.ed_key_file.is_symlink(),'Private key must be an explicit real file')
 note_data,patterns=inspect_private_inputs(app,notes,key,dest)
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());require(info.get('SUFeedURL')==args.feed_url,'Feed must match signed application configuration')
 version=info['CFBundleShortVersionString'];build=info['CFBundleVersion'];require(re.fullmatch(r'\d+(\.\d+){0,2}',version) is not None and re.fullmatch(r'\d+',build) is not None and int(build)<2**64,'Canonical release version/build required')
 feed_name=Path(urllib.parse.unquote(feed.path)).name;require(feed_name.endswith('.xml') and feed_name not in ('.','..'),'Explicit XML feed filename required')
 def run(command,capture=False):
  child=subprocess.Popen(command,start_new_session=True,stdout=subprocess.PIPE if capture else None,stderr=subprocess.PIPE if capture else None,text=True)
  try:
   output,_=child.communicate(timeout=180);require(child.returncode==0,'Release tool failed with exit '+str(child.returncode))
   return output.strip() if capture else None
  finally:
   if child.poll() is None:
    os.killpg(child.pid,signal.SIGTERM)
    try:child.wait(timeout=10)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
 run(['python3','-B',str(ROOT/'Scripts/validate-update-release.py'),str(app),'--architectures',args.architectures])
 sparkle=Path(subprocess.check_output(['python3','-B',str(ROOT/'Scripts/sparkle-dependency.py')],text=True).strip());signer=sparkle/'bin/sign_update';generator=sparkle/'bin/generate_appcast'
 with tempfile.TemporaryDirectory(prefix='autorender-release-',dir=dest.parent) as temporary:
  private=Path(temporary);tool=private/'key-check'
  run(['/usr/bin/swiftc','-target',platform.machine()+'-apple-macosx14.0',str(ROOT/'Scripts/UpdateSigningKey.swift'),'-o',str(tool)])
  run([str(tool),str(key),info['SUPublicEDKey']])
  stage=private/'release';stage.mkdir(mode=0o700)
  archive=stage/('AUTORENDER-'+version+'-'+build+'.zip');noteout=archive.with_suffix(notes.suffix.lower());noteout.write_bytes(note_data)
  run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(archive)])
  require(0<archive.stat().st_size<=args.max_archive_bytes,'Archive exceeds explicit publisher size bound')
  # Catch even a concurrent source mutation before anything reaches the output directory.
  with zipfile.ZipFile(archive) as package:
   for item in package.infolist():
    if item.is_dir():continue
    with package.open(item) as stream:require(not contains_secret(stream,patterns),'Private key content in archive')
  generator_args=[str(generator),'--ed-key-file',str(key),'--download-url-prefix',args.download_base_url,'--release-notes-url-prefix',args.notes_base_url,'--maximum-deltas','0','-o',str(stage/feed_name)]
  if args.channel=='prerelease':generator_args+=['--channel','prerelease']
  run([*generator_args,str(stage)])
  run([str(signer),'--verify','--ed-key-file',str(key),str(stage/feed_name)])
  namespace='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
  items=ET.parse(stage/feed_name).findall('channel/item');require(len(items)==1,'One exact archive item required')
  enclosure=items[0].find('enclosure');require(enclosure is not None and enclosure.attrib.get('url')==args.artifact_url,'Generated appcast URL differs from explicitly approved archive URL')
  require(enclosure.attrib.get('length')==str(archive.stat().st_size),'Generated appcast size differs from final archive')
  metadata=write_common_release(stage,archive,args.artifact_url,version,build,args.architectures,args.channel,info['SUPublicEDKey'],signer,key,run,args.allowed_host)
  require(enclosure.attrib.get(namespace+'edSignature')==metadata['artifact']['signature']['value'],'Archive/appcast signature mismatch')
  for item in stage.iterdir():
   if item.is_file():
    with item.open('rb') as stream:require(not contains_secret(stream,patterns),'Private key content in prepared output')
  receipt={'status':'PREPARED_SIGNED_NOT_PUBLISHED','input':str(app),'version':version,'build':build,'feed':args.feed_url,'files':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in stage.iterdir() if f.is_file()},'private_key_copied':False,'keychain_used':False,'installation_touched':False}
  (stage/'release-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
  system=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True);system.renamex_np.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];system.renamex_np.restype=ctypes.c_int
  if system.renamex_np(os.fsencode(stage),os.fsencode(dest),4)!=0:raise OSError(ctypes.get_errno(),'Exclusive release output rename failed')
  print(json.dumps(receipt))
if __name__=='__main__':
 signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(SystemExit(143)))
 try:main()
 except ReleaseInputError as error:raise SystemExit(str(error))
