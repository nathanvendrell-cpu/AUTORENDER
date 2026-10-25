#!/usr/bin/env python3
"""Inspect real bundle compatibility; production validation never signs, publishes or creates keys."""
import argparse,base64,json,plistlib,re,subprocess,urllib.parse
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('app',type=Path);parser.add_argument('--architectures',required=True,help='Comma-separated real release architectures');parser.add_argument('--package-only',action='store_true',help='Inspect ad-hoc candidate; never declares it release-ready');args=parser.parse_args();app=args.app.resolve();info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
def require(ok,reason):
 if not ok:raise SystemExit(reason)
def version(v):
 require(bool(re.fullmatch(r'\d+(\.\d+){0,2}',v)),'Unrecognized OS version')
 values=tuple(map(int,v.split('.')));return values+(0,)*(3-len(values))
def output(cmd):return subprocess.check_output(cmd,text=True)
expected=set(args.architectures.split(','));require(expected and expected<={'arm64','x86_64'},'Explicit supported release architectures required')
exe=app/'Contents/MacOS'/info['CFBundleExecutable'];require(exe.is_file() and not exe.is_symlink(),'Missing real bundle executable')
actual=set(output(['/usr/bin/lipo','-archs',str(exe)]).strip().split());require(actual==expected,'Release architectures differ from actual Mach-O executable')
require(info.get('CFBundleIdentifier')=='fr.robtech.rendubar','Unexpected application bundle identifier')
minimum=info.get('LSMinimumSystemVersion','');minimum_version=version(minimum)
def deployment_targets(payload,architectures):
 loads=output(['/usr/bin/otool','-arch','all','-l',str(payload)])
 blocks=re.split(r'Load command \d+\n',loads);minimums=[]
 for block in blocks:
  if re.search(r'cmd LC_BUILD_VERSION\b',block):
   platform=re.search(r'^\s*platform\s+(\S+)',block,re.M)
   require(platform is not None and platform.group(1) in ('1','MACOS'),'Embedded binary targets a non-macOS platform: '+str(payload.relative_to(app)))
   match=re.search(r'^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$',block,re.M)
  elif re.search(r'cmd LC_VERSION_MIN_MACOSX\b',block):
   match=re.search(r'^\s*version\s+(\d+(?:\.\d+){0,2})\s*$',block,re.M)
  else:continue
  require(match is not None,'Missing deployment target');minimums.append(match.group(1))
 require(len(minimums)==len(architectures),'Could not identify each macOS Mach-O slice: '+str(payload.relative_to(app)))
 require(all(version(v)<=minimum_version for v in minimums),'Mach-O requires newer macOS than Info.plist claims: '+str(payload.relative_to(app)))
 return minimums
binary_os=deployment_targets(exe,actual)
framework=app/'Contents/Frameworks/Sparkle.framework';require(framework.is_dir(),'Real Sparkle framework missing')
framework_arch=set(output(['/usr/bin/lipo','-archs',str(framework/'Sparkle')]).strip().split());require(actual<=framework_arch,'Sparkle architecture missing for application slice')
embedded_slices={}
for payload in app.rglob('*'):
 if not payload.is_file() or payload.is_symlink() or payload==exe:continue
 with payload.open('rb') as stream:magic=stream.read(4)
 if magic not in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):continue
 architectures=set(output(['/usr/bin/lipo','-archs',str(payload)]).strip().split())
 require(actual<=architectures,'Embedded Mach-O lacks application architecture: '+str(payload.relative_to(app)))
 embedded_slices[str(payload.relative_to(app))]={'architectures':sorted(architectures),'minimum_macos':deployment_targets(payload,architectures),'platform':'macOS'}
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
record={'app':str(app),'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'architectures':sorted(actual),'minimum_macos':minimum,'mach_o_minimums':binary_os,'framework_architectures':sorted(framework_arch),'embedded_mach_o_architectures':embedded_slices,'signature_valid':True}
if args.package_only:
 record['status']='PACKAGE_VERIFIED_NOT_RELEASE_READY';print(json.dumps(record));raise SystemExit(0)
url=urllib.parse.urlsplit(info.get('SUFeedURL',''));require(url.scheme=='https' and url.hostname and not url.username and not url.password and not url.fragment,'Release disabled: real HTTPS feed missing/invalid')
try:key=base64.b64decode(info.get('SUPublicEDKey',''),validate=True)
except ValueError:key=b''
require(len(key)==32 and any(key) and base64.b64encode(key).decode()==info.get('SUPublicEDKey'),'Release disabled: canonical nonzero Ed25519 public key missing')
team=info.get('AUTORENDERUpdateTeamID');require(bool(team),'Release disabled: expected Developer ID team missing')
require(info.get('SURequireSignedFeed') is True and info.get('SUVerifyUpdateBeforeExtraction') is True,'Signed feed and pre-extraction verification required')
expiration=info.get('SUSignedFeedFailureExpirationInterval');require(type(expiration) in (int,float) and expiration==0,'Signed feed validation must never expire')
require(info.get('SUAllowsAutomaticUpdates') is False and info.get('SUEnableAutomaticChecks') is False and info.get('SUAutomaticallyUpdate') is False,'Automatic checks and installation must be disabled')
r=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(app)],capture_output=True,text=True,check=True);details=r.stderr
require('Authority=Developer ID Application:' in details and 'TeamIdentifier='+team in details,'Real Developer ID signature/team required; ad-hoc fixtures are not production')
subprocess.run(['/usr/bin/xcrun','stapler','validate',str(app)],check=True)
record.update(status='RELEASE_CONTRACT_VALIDATED_NOT_PUBLISHED',feed=info['SUFeedURL'],team=team);print(json.dumps(record))
