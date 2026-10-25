"""Pure, bounded interpretation of same-user Windows renderer observations.

No process launch, producer import, filesystem search or network access here.
Command lines and producer source are transient inputs, never output fields.
"""
import ast
import datetime
import hashlib
import ntpath
import re

MAX_PROCESSES = 64
MAX_JOBS = 50
MAX_ARGUMENT_BYTES = 4096
MAX_SOURCE_BYTES = 32768


def date(value):
    try:
        result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        return result if result.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def norm(value):
    return ntpath.normpath(value).replace('\\', '/').lower()


def absolute(value):
    return isinstance(value, str) and len(value) <= 4096 and bool(re.match(r'^[A-Za-z]:[\\/]', value)) and not any(ord(c) < 32 for c in value)


def windows_arguments(command):
    """Windows double-quote/backslash rules, without shell evaluation."""
    if not isinstance(command, str) or len(command.encode('utf-8')) > MAX_ARGUMENT_BYTES or '\x00' in command:
        return None
    result, index = [], 0
    while index < len(command):
        while index < len(command) and command[index] in ' \t':
            index += 1
        if index == len(command):
            break
        word, quoted = [], False
        while index < len(command) and (quoted or command[index] not in ' \t'):
            slashes = 0
            while index < len(command) and command[index] == '\\':
                slashes += 1
                index += 1
            if index < len(command) and command[index] == '"':
                word.extend('\\' * (slashes // 2))
                if slashes % 2:
                    word.append('"')
                elif quoted and index + 1 < len(command) and command[index + 1] == '"':
                    word.append('"')
                    index += 1
                else:
                    quoted = not quoted
                index += 1
            else:
                word.extend('\\' * slashes)
                if index < len(command) and (quoted or command[index] not in ' \t'):
                    word.append(command[index])
                    index += 1
        if quoted:
            return None
        result.append(''.join(word))
        if len(result) > 256:
            return None
    return result


def positive(value):
    return int(value) if isinstance(value, str) and re.fullmatch(r'[0-9]{1,7}', value) and 0 < int(value) <= 1_000_000 else None


def seconds(value):
    if not isinstance(value, str):
        return None
    if re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', value):
        number = float(value)
    elif re.fullmatch(r'[0-9]{1,4}:[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?', value):
        h, m, s = value.split(':')
        number = int(h) * 3600 + int(m) * 60 + float(s)
    else:
        return None
    return number if 0 < number <= 31_536_000 else None


def static_producer(row, script, born):
    """A small definite-call AST profile; unsupported control flow stays unknown."""
    source = row.get('producerSource')
    if not isinstance(source, dict) or not script or norm(source.get('path', '')) != norm(script):
        return False
    text = source.get('text')
    modified = date(source.get('modified'))
    if not isinstance(text, str) or len(text.encode('utf-8')) > MAX_SOURCE_BYTES or not modified or modified > born:
        return False
    if hashlib.sha256(text.encode('utf-8')).hexdigest() != source.get('sha256'):
        return False
    try:
        tree = ast.parse(text)
        nodes = list(ast.walk(tree))
        if len(nodes) > 10000 or not any(isinstance(n, ast.Import) and any(a.name == 'bpy' and a.asname is None for a in n.names) for n in tree.body):
            return False
        if any((isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id == 'bpy') or (isinstance(n, ast.Attribute) and isinstance(n.ctx, ast.Store) and ast.unparse(n).startswith('bpy.')) or (isinstance(n, (ast.alias,)) and n.asname == 'bpy') for n in nodes):
            return False
        definitions = [n for n in tree.body if isinstance(n, ast.FunctionDef)]
        functions = {n.name: n for n in definitions}
        if len(functions) != len(definitions):
            return False

        def definite(body, depth=0):
            if depth > 3:
                return False
            for node in body:
                if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
                    call = node.value
                    if ast.unparse(call.func) in ['exit', 'quit', 'sys.exit', 'os._exit']:
                        return False
                    if ast.unparse(call.func) == 'bpy.ops.render.render' and not call.args:
                        if any(k.arg in ['animation', 'write_still'] and isinstance(k.value, ast.Constant) and k.value.value is True for k in call.keywords):
                            return True
                    if isinstance(call.func, ast.Name) and call.func.id in functions and not call.args and not call.keywords:
                        target = functions[call.func.id]
                        if not target.args.args and not target.args.kwonlyargs and not target.args.vararg and not target.args.kwarg and not target.decorator_list and definite(target.body, depth + 1):
                            return True
                if isinstance(node, ast.If) and ast.dump(node.test, include_attributes=False) == ast.dump(ast.parse("__name__ == '__main__'", mode='eval').body, include_attributes=False):
                    if definite(node.body, depth + 1):
                        return True
                if isinstance(node, ast.For):
                    try:
                        values = ast.literal_eval(node.iter)
                    except (ValueError, TypeError):
                        values = None
                    if isinstance(node.iter, ast.Call) and isinstance(node.iter.func, ast.Name) and node.iter.func.id == 'range' and not node.iter.keywords:
                        try:
                            numbers = [ast.literal_eval(arg) for arg in node.iter.args]
                            if all(type(n) is int for n in numbers) and 1 <= len(numbers) <= 3:
                                sequence = range(*numbers)
                                values = [1] if 0 < len(sequence) <= 20000 else None
                        except (ValueError, TypeError, OverflowError):
                            values = None
                    if isinstance(values, (list, tuple)) and values and definite(node.body, depth + 1):
                        return True
                if isinstance(node, (ast.Return, ast.Raise, ast.Break, ast.Continue, ast.While, ast.Try)):
                    return False
            return False
        return definite(tree.body)
    except (SyntaxError, ValueError, RecursionError, TypeError):
        return False


def blender(args, row, born):
    background = False
    scene = script = output = scene_name = None
    start = end = None
    step = 1
    actions = []
    ambiguous = False
    index = 1
    values = {'-t', '--threads', '-E', '--engine', '-F', '--render-format', '-x', '--use-extension', '-S', '--scene', '--log-level', '--python-exit-code'}
    switches = {'--factory-startup', '--disable-autoexec', '--enable-autoexec', '-y', '--debug', '--debug-cycles', '-noaudio'}
    while index < len(args):
        arg = args[index]
        if arg == '--':
            break
        if arg in ['-b', '--background']:
            background = True
        elif arg in set(['-P', '--python', '-o', '--render-output', '-s', '--frame-start', '-e', '--frame-end', '-j', '--frame-jump']) | values:
            if index + 1 >= len(args):
                return None
            value = args[index + 1]
            if arg in ['-P', '--python']:
                script = value
            elif arg in ['-S', '--scene']:
                scene_name = value
            elif arg in ['-o', '--render-output']:
                output = value
            elif arg in ['-s', '--frame-start']:
                start = positive(value)
            elif arg in ['-e', '--frame-end']:
                end = positive(value)
            elif arg in ['-j', '--frame-jump']:
                step = positive(value)
            index += 1
        elif arg in ['-a', '--render-anim', '-f', '--render-frame']:
            total = None
            if arg in ['-f', '--render-frame']:
                index += 1
                if index >= len(args):
                    return None
                if positive(args[index]):
                    total = 1
            elif start and end and step and end >= start:
                total = (end - start) // step + 1
            actions.append(total)
        elif arg in switches:
            pass
        elif not arg.startswith('-') and arg.lower().endswith('.blend'):
            if actions:
                ambiguous = True
            scene = arg
            output = None
            scene_name = None
            start = end = None
            step = 1
        else:
            ambiguous = True
        index += 1
    if not background or ambiguous:
        return None
    if len(actions) == 1 and scene and script is None:
        return {'evidence': 'render_command', 'title': ntpath.basename(scene), 'total': actions[0], 'output': output, 'sourceContext': {'filePath': scene if absolute(scene) else None, 'sceneName': scene_name, 'outputPath': output if absolute(output) else None, 'origin': 'commandLine'}}
    if not actions and script and absolute(script) and static_producer(row, script, born):
        return {'evidence': 'static_producer', 'title': ntpath.basename(scene or script), 'total': None, 'output': None, 'sourceContext': {'filePath': scene if absolute(scene) else None, 'scriptPath': script, 'origin': 'staticProducer'}}
    return None


def ffmpeg(args):
    values = {'-i', '-c:v', '-codec:v', '-vcodec', '-c:a', '-codec:a', '-acodec', '-c', '-codec', '-vf', '-af', '-filter:v', '-filter:a', '-filter_complex', '-r', '-s', '-pix_fmt', '-b:v', '-b:a', '-crf', '-preset', '-t', '-to', '-ss', '-frames:v', '-vframes', '-frames:a', '-f', '-map', '-metadata', '-loglevel', '-threads', '-progress', '-vsync', '-fps_mode', '-bufsize', '-hwaccel', '-hwaccel_output_format', '-cq', '-q:v', '-ar', '-ac', '-start_number', '-movflags', '-level', '-profile:v', '-maxrate'}
    switches = {'-y', '-n', '-nostdin', '-hide_banner', '-an', '-vn', '-sn', '-dn', '-shortest', '-stats', '-nostats'}
    inputs = 0
    outputs = []
    total = duration = progress = None
    index = 1
    while index < len(args):
        arg = args[index]
        if arg in switches:
            index += 1
            continue
        if arg in values:
            if index + 1 >= len(args):
                return None
            value = args[index + 1]
            if arg == '-i':
                inputs += 1
                total = duration = None
            elif arg in ['-frames:v', '-vframes']:
                total = positive(value)
            elif arg == '-t':
                duration = seconds(value)
            elif arg == '-progress':
                progress = value
            index += 2
            continue
        if arg.startswith('-'):
            return None
        outputs.append(arg)
        index += 1
    if not inputs or not outputs or any('://' in p or p.startswith('pipe:') or p == '-' for p in outputs):
        return None
    return {'evidence': 'render_command', 'title': ntpath.basename(outputs[0]), 'total': total if len(outputs) == 1 else None, 'duration': duration if len(outputs) == 1 else None, 'progress': progress if absolute(progress) else None, 'output': outputs[0]}


def progress_sample(row, parsed, born, observed):
    sample = row.get('progressFile')
    if not isinstance(sample, dict) or not parsed.get('progress') or norm(sample.get('path', '')) != norm(parsed['progress']):
        return {}
    modified = date(sample.get('modified'))
    text = sample.get('text')
    if not modified or not born <= modified <= observed or not isinstance(text, str) or len(text.encode('utf-8')) > 8192:
        return {}
    fields = {}
    block = {}
    for line in text.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            block[key.strip()] = value.strip()
            if key.strip() == 'progress':
                fields = block
                block = {}
    if not fields:
        return {}
    result = {'progressObservedAt': sample['modified']}
    if re.fullmatch(r'[0-9]{1,7}', fields.get('frame', '')):
        n = int(fields['frame'])
        if n <= 1_000_000 and (parsed.get('total') is None or n <= parsed['total']):
            result['completedFrames'] = n
    position = None
    # FFmpeg out_time_us and legacy out_time_ms both report microseconds.
    for key in ['out_time_us', 'out_time_ms']:
        if re.fullmatch(r'[0-9]{1,16}', fields.get(key, '')):
            position = int(fields[key]) / 1_000_000
            break
    if position is None:
        position = seconds(fields.get('out_time'))
    if position is not None and 0 <= position <= 31_536_000 and (parsed.get('duration') is None or position <= parsed['duration']):
        result['mediaPositionSeconds'] = position
    result['completedSignal'] = not block and fields.get('progress') == 'end' and parsed.get('total') is not None and result.get('completedFrames') == parsed['total']
    return result


def blender_handler(row, born, observed, event=None, container_at=None):
    """Only the PID-derived private file, already read by the bounded collector."""
    import json
    sample = row.get('blenderRelay')
    if not isinstance(sample, dict) or not isinstance(sample.get('text'), str) or len(sample['text'].encode('utf-8')) > 8192:
        return None
    try:
        historical = event is not None
        if not historical:
            event = json.loads(sample['text'])
        at, started, event_at, modified = (date(event.get('observedAt')), date(event.get('startedAt')), date(event.get('eventAt')), date(sample.get('modified')))
        token = event.get('invocationToken')
        container_at = container_at or at
        if historical and event.get('state') not in ['complete', 'cancel']:
            return None
        current_frame = event.get('currentFrame')
        if current_frame is not None and (type(current_frame) is not int or not -(2**31) <= current_frame < 2**31):
            return None
        count = event.get('completedFrames')
        writes = event.get('writtenFrames')
        durations = event.get('durationsSeconds')
        if (event.get('schemaVersion') != 1 or event.get('pid') != row['pid'] or not isinstance(row.get('birthToken'), str)
                or not re.fullmatch(r'[0-9]{15,20}', row['birthToken']) or event.get('birthToken') != row['birthToken']
                or not isinstance(token, str) or not re.fullmatch('[a-f0-9]{32}', token)
                or not all([at, started, event_at, modified]) or not born <= started <= event_at <= at <= observed
                or not container_at or not at <= container_at <= observed
                or (observed-container_at).total_seconds() > (120 if historical else 15) or abs((modified-container_at).total_seconds()) > 3
                or event.get('state') not in ['active', 'unknown', 'complete', 'cancel']
                or event.get('phase') not in ['init', 'pre', 'post', 'write', 'complete', 'cancel']
                or type(count) is not int or not 0 <= count <= 1_000_000
                or type(writes) is not int or not 0 <= writes <= 1_000_000
                or not isinstance(durations, list) or len(durations) > 16
                or any(type(n) not in [float, int] or not 0 < n <= 86400 for n in durations)):
            return None
        if event['state'] in ['complete', 'cancel'] and event['phase'] != event['state']:
            return None
        driver_started = date(event.get('driverStartedAt')) or started
        if not born <= driver_started <= started:
            return None
        active = event['state'] == 'active' and event.get('jobRunning') is not False
        return {'evidence': 'blender_handler', 'title': clean(event.get('title') or 'Blender'), 'total': None,
                'invocationToken': token, 'nativeState': event['state'] if active or event['state'] in ['complete', 'cancel'] else 'unknown', 'qualified': active or event['state'] in ['complete', 'cancel'],
                'count': count, 'eventAt': event['eventAt'], 'renderStartedAt': event['startedAt'], 'currentFrame': current_frame, 'driverStartedAt': driver_started.isoformat(), 'processBirthToken': row.get('birthToken'), 'exportArtifact': sanitized_export(event.get('exportArtifact')), 'outputManifest': sanitized_manifest(event.get('outputManifest')),  'writtenFrames': writes, 'sourceContext': event.get('sourceContext') if isinstance(event.get('sourceContext'), dict) else None}
    except (KeyError, ValueError, TypeError, AttributeError, OverflowError):
        return None


def sanitized_manifest(value):
    if not isinstance(value, dict) or not isinstance(value.get('id'),str) or not re.fullmatch('[a-f0-9]{32,64}', value['id']) or not isinstance(value.get('indexPath'),str) or not isinstance(value.get('sha256'),str) or not re.fullmatch('[a-f0-9]{64}',value['sha256']) or type(value.get('expectedCount')) is not int or not 1 <= value['expectedCount'] <= 50000 or type(value.get('complete')) is not bool:
        return None
    return {k:value[k] for k in ('id','indexPath','sha256','expectedCount','complete')}


def sanitized_export(value):
    if not isinstance(value, dict):
        return None
    path, sha, size = value.get('path'), value.get('sha256'), value.get('bytes')
    if not isinstance(path, str) or not re.fullmatch(r'[A-Za-z]:[/\\][^\x00-\x1f\x7f]{1,390}', path) or '..' in path.replace('\\', '/').split('/') or not isinstance(sha, str) or not re.fullmatch('[a-f0-9]{64}', sha) or type(size) is not int or not 0 < size <= 2147483648:
        return None
    return {'path': path, 'sha256': sha, 'bytes': size}


def blender_idle(row, born, observed):
    import json
    try:
        sample = row.get('blenderRelay', {})
        text = sample.get('text', '')
        if not isinstance(text, str) or len(text.encode('utf-8')) > 8192:
            return False
        event = json.loads(text)
        at, modified = date(event.get('observedAt')), date(sample.get('modified'))
        return (event.get('schemaVersion') == 1 and event.get('pid') == row['pid']
                and isinstance(row.get('birthToken'), str) and re.fullmatch(r'[0-9]{15,20}', row['birthToken']) is not None
                and event.get('birthToken') == row['birthToken'] and event.get('state') == 'idle' and event.get('jobRunning') is False
                and event.get('invocationToken') is None and event.get('startedAt') is None
                and at is not None and modified is not None and born <= at <= observed
                and (observed-at).total_seconds() <= 15 and abs((modified-at).total_seconds()) <= 3)
    except (TypeError, ValueError, KeyError, AttributeError):
        return False


def blender_history(row, born, observed):
    import json
    try:
        sample = row.get('blenderRelay', {})
        text = sample.get('text', '')
        if len(text.encode('utf-8')) > 8192:
            return []
        packet = json.loads(text)
        events = packet.get('recentInvocations', [])
        container_at = date(packet.get('observedAt'))
        if not isinstance(events, list) or len(events) > 8:
            return []
        result, seen = [], {packet.get('invocationToken')}
        for event in events:
            parsed = blender_handler(row, born, observed, event=event, container_at=container_at)
            if parsed and parsed['invocationToken'] not in seen:
                result.append(parsed)
                seen.add(parsed['invocationToken'])
        return result
    except (KeyError, TypeError, ValueError, AttributeError):
        return []


def snapshot(raw, claimed=()):
    if raw.get('processSchema') != 1:
        return None
    observed = date(raw.get('observedAt'))
    if observed is None:
        raise ValueError('process date')
    rows = raw.get('processes', [])
    if not isinstance(rows, list) or len(rows) > MAX_PROCESSES:
        raise ValueError('process bound')
    observations = []
    historical = []
    coverage = not raw.get('processPartial', raw.get('partial', True))
    scope = raw.get('connectionScope', hashlib.sha256(b'unspecified-scope').hexdigest())
    if not isinstance(scope, str) or not re.fullmatch('[a-f0-9]{64}', scope):
        raise ValueError('connection scope')
    seen = set()
    progress_owners = {}
    for row in rows:
        if not isinstance(row, dict):
            coverage = False
            continue
        args = windows_arguments(row.get('argv'))
        if args:
            for index, arg in enumerate(args[:-1]):
                if arg == '-progress' and absolute(args[index + 1]):
                    key = norm(args[index + 1]);progress_owners[key] = progress_owners.get(key, 0) + 1
    for row in rows:
        if not isinstance(row, dict):
            continue
        exe = row.get('executable')
        engine = ntpath.basename(exe).casefold() if absolute(exe) else ''
        if engine not in ['blender.exe', 'ffmpeg.exe']:
            if str(row.get('name', '')).lower().removesuffix('.exe') in ['blender', 'ffmpeg']:
                coverage = False
            continue
        born = date(row.get('birth'))
        pid = row.get('pid')
        if type(pid) is not int or not 0 < pid < 2**31 or born is None or born > observed or row.get('ownerVerified') is not True or row.get('revalidated') is not True:
            coverage = False
            continue
        if (pid, row['birth']) in seen:
            coverage = False
            continue
        seen.add((pid, row['birth']))
        if (pid, row['birth']) in claimed:
            continue
        args = windows_arguments(row.get('argv'))
        parsed = None
        if args and (norm(args[0]) == norm(exe) or args[0].casefold() == ntpath.basename(exe).casefold()):
            parsed = blender(args, row, born) if engine == 'blender.exe' else ffmpeg(args)
        relay = blender_handler(row, born, observed) if engine == 'blender.exe' else None
        background = engine == 'blender.exe' and args and any(arg in ['-b', '--background'] for arg in args[1:args.index('--') if '--' in args else len(args)])
        if engine == 'blender.exe' and not background and parsed is None and blender_idle(row, born, observed):
            continue  # Proven idle GUI process: no render invocation/job or completion is fabricated.
        background_event = relay if background else None
        # CLI is a process task, including a script loop. GUI invocation tokens never split it.
        if background:
            if parsed is None and relay and relay['qualified'] and relay['nativeState'] == 'active':
                parsed = {'evidence': 'blender_handler', 'title': relay['title'], 'total': None}
            relay = None
        elif relay is not None and not relay['qualified'] and parsed is not None:
            relay = None
        elif relay is not None:
            parsed = relay
        identity_text = scope+'|'+str(pid)+'|'+row['birth']+'|'+norm(exe)

        def item_for(parsed, native=None):
            identity = identity_text + ('|'+native['invocationToken'] if native else '')
            item = {'connectionScope': scope, 'pid': pid, 'birth': row['birth'], 'executable': exe, 'engine': engine[:-4],
                    'id': 'shadow:process:' + hashlib.sha256(identity.encode('utf-8')).hexdigest(), 'observedAt': raw['observedAt'],
                    'qualified': parsed is not None, 'evidence': parsed['evidence'] if parsed else None,
                    'title': clean(parsed['title'] if parsed else engine[:-4]), 'completedFrames': None, 'totalFrames': parsed.get('total') if parsed else None, 'sourceContext': parsed.get('sourceContext') if parsed else None}
            if native:
                item['qualified'] = native['qualified']
                item['evidence'] = 'blender_handler' if native['qualified'] else None
                item['processBirthToken'] = native['processBirthToken']
                item['exportArtifact'] = native['exportArtifact']
                item['outputManifest'] = native['outputManifest']
                item['writtenFrames'] = native['writtenFrames']
                item['sourceContext'] = native['sourceContext']
                item.update(invocationToken=native['invocationToken'], nativeState=native['nativeState'], renderStartedAt=native['renderStartedAt'], currentFrame=native['currentFrame'], completedFrames=native['count'] if native['qualified'] else None, progressObservedAt=native['eventAt'] if native['qualified'] else None)
            return item

        item = item_for(parsed, relay)
        if background_event:
            if parsed is None:
                item['title'] = background_event['title']
            item['backgroundProcess'] = True
            item['renderStartedAt'] = background_event['driverStartedAt']
            item['currentFrame'] = background_event['currentFrame']
        if parsed:
            item['mediaDurationSeconds'] = parsed.get('duration')
            if parsed.get('progress') and progress_owners.get(norm(parsed['progress'])) == 1:
                item.update(progress_sample(row, parsed, born, observed))
        observations.append(item)
        if engine == 'blender.exe' and not background:
            historical.extend(item_for(event, event) for event in blender_history(row, born, observed))
    def active(row):
        return row['qualified'] and row.get('nativeState') not in ['complete', 'cancel'] and row.get('completedSignal') is not True
    actives = [row for row in observations if active(row)]
    candidates = [row for row in observations if not row['qualified']]
    completed = [row for row in observations if row['qualified'] and not active(row)] + historical
    if len(actives) > MAX_JOBS:
        coverage = False
    retained = actives[:MAX_JOBS] + candidates
    seen_ids = {row['id'] for row in retained}
    completed.sort(key=lambda row: row.get('progressObservedAt') or row['observedAt'], reverse=True)
    kept_completed = []
    for row in completed:
        if row['id'] not in seen_ids and len(kept_completed) < min(64, 128-len(retained)):
            kept_completed.append(row)
            seen_ids.add(row['id'])
    observations = retained + kept_completed
    return {'schemaVersion': 1, 'observedAt': raw['observedAt'], 'coverageComplete': coverage, 'connectionScope': scope, 'historyTruncated': len(kept_completed) < len(completed), 'observations': observations}


def json_bytes(value):
    import json
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def clean(value):
    return ''.join(c for c in value if ord(c) >= 32)[:256] or 'Rendu PC'
