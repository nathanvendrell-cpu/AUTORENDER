"""Bounded one-shot managed-library transport. No calls occur on import.
Only future, native-attested final media may be read or reversibly retired.
"""
import argparse, base64, datetime, gzip, hashlib, json, os, re, signal, subprocess, sys, time, uuid, stat
from pathlib import Path
import shadow_collector as transport

BOOTSTRAP = "$ErrorActionPreference='Stop';$b=[Convert]::FromBase64String([Console]::In.ReadToEnd());$m=[IO.MemoryStream]::new($b);$z=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);$r=[IO.StreamReader]::new($z,[Text.Encoding]::UTF8);try{& ([ScriptBlock]::Create($r.ReadToEnd()))}finally{$r.Dispose();$z.Dispose();$m.Dispose()}"
HEX = re.compile(r'^[a-f0-9]{64}$')


def validate(request, host, user):
    if not isinstance(request, dict) or request.get('operation') not in ('stage', 'retire', 'restore', 'policy', 'manifest'):
        raise ValueError('operation')
    activated = datetime.datetime.fromisoformat(request['activatedAt'].replace('Z', '+00:00'))
    if activated.tzinfo is None or activated.timestamp() > time.time():
        raise ValueError('activation')
    if request['operation'] == 'policy':
        p = request.get('policy', {})
        if p.get('activatedAt') != request['activatedAt'] or p.get('schemaVersion') != 1 or type(p.get('enabled')) is not bool or type(p.get('exportInMemory')) is not bool:
            raise ValueError('policy')
        return
    a = request.get('artifact', {})
    if a.get('connectionScope') != hashlib.sha256((host+'|'+user).encode()).hexdigest():
        raise ValueError('connection-changed')
    path = a.get('path')
    if not isinstance(path, str) or not transport.valid_path(path) or Path(path.replace('\\', '/')).suffix.lower() not in {'.png','.jpg','.jpeg','.webp','.exr','.tif','.tiff','.mp4','.mov','.mkv','.wav','.flac','.mp3','.aif','.aiff'}:
        raise ValueError('media-path')
    if not re.fullmatch('[a-f0-9]{32}', a.get('invocationToken', '')) or type(a.get('processID')) is not int or (a['processID'] <= 0 and not a.get('scriptProof')) or not re.fullmatch('[0-9]{1,20}', a.get('birthToken', '')):
        raise ValueError('invocation')
    start = datetime.datetime.fromisoformat(a['startedAt'].replace('Z', '+00:00'))
    end = datetime.datetime.fromisoformat(a['completedAt'].replace('Z', '+00:00'))
    if start < activated or end < start or end.timestamp() > time.time():
        raise ValueError('future-final-job-only')
    if request['operation'] not in ('stage', 'manifest') and (not HEX.fullmatch(request.get('transactionID', '')) or not HEX.fullmatch(request.get('sha256', ''))):
        raise ValueError('transaction')


def invocation(request):
    data = base64.b64encode(json.dumps({k:v for k,v in request.items() if not k.startswith('_')}, separators=(',', ':')).encode()).decode()
    script = Path(__file__).with_name('remote_library.ps1').read_text().replace('__REQUEST__', data)
    if len(script.encode()) > 65536:
        raise ValueError('script-size')
    command = 'powershell -NoProfile -NonInteractive -EncodedCommand ' + base64.b64encode(BOOTSTRAP.encode('utf-16-le')).decode()
    return command, base64.b64encode(gzip.compress(script.encode(), mtime=0))+b'\n'


def remote_json(request, endpoint):
    command, stdin = invocation(request)
    data = transport.run(['ssh', *endpoint, command], 35, input_bytes=stdin)
    if len(data) > 524288:
        raise ValueError('response-size')
    value = json.loads(data.decode('utf-8-sig').strip())
    if value.get('ok') is not True:
        raise ValueError('remote-refused')
    return value


def stream(request, endpoint, destination, maximum):
    command, stdin = invocation(dict(request, operation='read'))
    with destination.open('xb') as out:
        os.chmod(destination, 0o600)
        with subprocess.Popen(['ssh', *endpoint, command], stdin=subprocess.PIPE, stdout=out, stderr=subprocess.DEVNULL, start_new_session=True) as process:
            transport.ACTIVE = process
            try:
                process.stdin.write(stdin); process.stdin.close()
                deadline = time.monotonic()+120
                while process.poll() is None:
                    if time.monotonic() > deadline or out.tell() > maximum:
                        raise TimeoutError('bounded-stream')
                    time.sleep(.1)
                if process.returncode or out.tell() != maximum:
                    raise ValueError('incomplete-stream')
                out.flush(); os.fsync(out.fileno())
            finally:
                transport.stop_active(); process.wait(); transport.ACTIVE = None


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024), b''): h.update(b)
    return h.hexdigest()


def safe_local(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts or any(p.is_symlink() for p in [path, *path.parents]) or not path.parent.is_dir():
        raise ValueError('staging-path')
    return path


def stage(request, endpoint, remote=remote_json, download=stream, pause=time.sleep):
    path = safe_local(request['localFile'])
    entries = list(path.parent.iterdir())
    if len(entries) >= 128 and not path.exists():
        raise ValueError('staging-area-full')
    probe = dict(request, operation='inspect')
    first = remote(probe, endpoint)
    if not HEX.fullmatch(first.get('sha256', '')) or not 0 < first.get('bytes', 0) <= 2*1024**3:
        raise ValueError('artifact-bound')
    expected = request['artifact'].get('expectedSHA256')
    if expected and expected != first['sha256']:
        raise ValueError('export-hash-mismatch')
    temporary = path.with_name('.autoren-transfer-'+uuid.uuid4().hex+'.partial')
    created = False
    try:
        if path.exists():
            if not path.is_file() or sha(path) != first['sha256']:
                raise ValueError('staging-collision')
        else:
            if temporary.exists():
                raise ValueError('staging-partial-needs-recovery')
            created = True
            download(dict(probe, sha256=first['sha256']), endpoint, temporary, first['bytes'])
            if sha(temporary) != first['sha256']:
                raise ValueError('download-hash-mismatch')
            os.link(temporary, path)
            temporary.unlink()
        before = path.stat(follow_symlinks=False)
        local_first = datetime.datetime.now(datetime.timezone.utc).isoformat()
        pause(8.05)
        second = remote(dict(probe, sha256=first['sha256']), endpoint)
        after = path.stat(follow_symlinks=False)
        fields = ('st_dev','st_ino','st_size','st_mtime_ns')
        if any(getattr(before, f) != getattr(after, f) for f in fields) or (first['sha256'],first['identity'],first['bytes']) != (second.get('sha256'),second.get('identity'),second.get('bytes')) or sha(path) != first['sha256']:
            raise ValueError('source-not-stable')
        return dict(ok=True, sha256=first['sha256'], bytes=first['bytes'], localFile=str(path), firstObservedAt=local_first, secondObservedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    finally:
        if created and temporary.exists() and not temporary.is_symlink() and stat.S_ISREG(temporary.lstat().st_mode):
            temporary.unlink()


def manifest_page(request, endpoint):
    value = remote_json(request, endpoint)
    d = value['descriptor']
    if not d.get('complete') or not 0 < d.get('expectedCount',0) <= 50000 or not HEX.fullmatch(d.get('sha256','')) or not 1 <= len(value.get('artifacts',[])) <= 32:
        raise ValueError('manifest-proof')
    for artifact in value['artifacts']:
        remote = dict(request['artifact'], path=artifact['path'], manifest=d, manifestPagePath=value['pagePath'], manifestPageSHA256=value['pageSHA256'])
        validate(dict(request, operation='stage', artifact=remote), *request['_endpointIdentity'])
        artifact['remote'] = remote
    return value


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--request-json', required=True); args = parser.parse_args()
    if len(args.request_json.encode()) > 16384: raise ValueError('request-size')
    request = json.loads(args.request_json)
    host, user, key = transport.connection(); validate(request, host, user)
    endpoint = [*transport.ssh_base(key), '-o', 'ControlMaster=no', '-o', 'ControlPath=none', f'{user}@{host}']
    if request['operation']=='manifest':
        request['_endpointIdentity'] = (host,user)
        return manifest_page(request, endpoint)
    return stage(request, endpoint) if request['operation']=='stage' else remote_json(request, endpoint)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, transport.interrupt); signal.signal(signal.SIGINT, transport.interrupt)
    try:
        print(json.dumps(main(), separators=(',', ':')))
    except (Exception, KeyboardInterrupt) as exc:
        print(json.dumps({'ok':False, 'reason':type(exc).__name__}), file=sys.stderr); sys.exit(1)
    finally:
        transport.stop_active()
