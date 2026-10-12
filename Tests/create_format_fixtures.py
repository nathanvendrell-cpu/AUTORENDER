#!/usr/bin/env python3
"""Create bounded offline format fixtures for FormatScannerSmoke. Requires FFmpeg and macOS sips.
Usage: python3 Tests/create_format_fixtures.py /absolute/temporary-fixture-directory
No live project, configuration, network, UI or playback is accessed.
PDF/3D fixtures are structural examples; their renderability is not certified.
"""
import subprocess, pathlib, json, struct, zipfile, os, time, sys
base=pathlib.Path(sys.argv[1]).resolve()
base.mkdir(parents=True,exist_ok=True)
records=[]
def run(args,label,timeout=60):
    proc=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    record={'label':label,'pid':proc.pid,'args':args}
    records.append(record)
    try:
        out=proc.communicate(timeout=timeout)[0]
    except BaseException:
        os.killpg(proc.pid,15)
        try:proc.communicate(timeout=3)
        except subprocess.TimeoutExpired:os.killpg(proc.pid,9);proc.communicate()
        raise
    record['returncode']=proc.returncode
    (base/(label+'.log')).write_bytes(out)
    if proc.returncode:raise RuntimeError(label+': '+out.decode(errors='replace')[-1600:])
    print(label+': PASS',flush=True)
    return out
try:
    formats=base/'formats';formats.mkdir(exist_ok=True)
    for ext in ['png','jpg','jpeg','tif','tiff','exr']:
        run(['ffmpeg','-v','error','-y','-f','lavfi','-i','color=c=blue:s=16x16:r=1','-frames:v','1',str(formats/('image.'+ext))],'create-'+ext)
    for ext in ['mp4','mov','m4v','avi']:
        run(['ffmpeg','-v','error','-y','-f','lavfi','-i','color=c=blue:s=16x16:r=10','-t','0.2','-c:v','mpeg4',str(formats/('clip.'+ext))],'create-'+ext)
    for ext in ['wav','aif','aiff','flac','mp3','m4a','aac','ogg']:
        run(['ffmpeg','-v','error','-y','-f','lavfi','-i','sine=frequency=440:duration=0.2',str(formats/('sound.'+ext))],'create-'+ext)
    gltf=json.dumps({'asset':{'version':'2.0'},'scene':0,'scenes':[{'nodes':[]}]}).encode()
    (formats/'scene.gltf').write_bytes(gltf)
    gltf+=b' '*((-len(gltf))%4)
    (formats/'scene.glb').write_bytes(struct.pack('<III',0x46546c67,2,20+len(gltf))+struct.pack('<II',len(gltf),0x4e4f534a)+gltf)
    with zipfile.ZipFile(formats/'scene.usdz','w',compression=zipfile.ZIP_STORED) as z:
        info=zipfile.ZipInfo('scene.usda');info.extra=b'\x01\x00'+struct.pack('<H',64-(30+len('scene.usda')+4)%64)+bytes(64-(30+len('scene.usda')+4)%64)
        z.writestr(info,'#usda 1.0\n( defaultPrim = "Root" )\ndef Xform "Root" {}\n')
    # Minimal valid single blank page PDF with correct xref offsets.
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>']
    pdf=b'%PDF-1.4\n'; offsets=[0]
    for i,obj in enumerate(objects,1):offsets.append(len(pdf));pdf+=str(i).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
    xref=len(pdf);pdf+=b'xref\n0 4\n0000000000 65535 f \n'+b''.join(f'{x:010d} 00000 n \n'.encode() for x in offsets[1:])+b'trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n'
    (formats/'page.pdf').write_bytes(pdf)
    for ext in ['tif','tiff']:
        run(['sips','-s','format','tiff',str(formats/'image.png'),'--out',str(formats/('rgb-image.'+ext))],'create-rgb-'+ext)
    sequence=base/'sequence';sequence.mkdir(exist_ok=True)
    run(['ffmpeg','-v','error','-y','-f','lavfi','-i','testsrc=size=16x16:rate=3','-frames:v','3',str(sequence/'frame_%03d.png')],'create-sequence')
    for file in formats.iterdir():os.utime(file,(time.time()-40,time.time()-40))
    for file in formats.iterdir():
        if file.suffix in ['.glb','.gltf','.usdz','.pdf']:continue
        run(['ffprobe','-v','error','-show_entries','format=format_name','-of','json',str(file)],'probe-'+file.suffix[1:])
finally:
    (base/'fixture-processes.json').write_text(json.dumps(records,indent=2))
