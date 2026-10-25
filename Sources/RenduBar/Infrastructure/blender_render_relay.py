"""AUTORENDER Blender startup relay, schema 1. No scene/settings mutations; optional final Render Result export.

register() only installs persistent handlers and a Blender timer (RestrictBlend safe).
Default writes only process-owned LOCALAPPDATA/AUTORENDER/Blender/<PID>.json.
An explicit future-jobs policy enables bounded outbox image export after idle completion.
API: https://docs.blender.org/api/5.1/bpy.app.handlers.html
"""
import ctypes
import datetime
import json
import hashlib
import ntpath
import os
from pathlib import Path
import threading
import time
import uuid

bl_info = {'name': 'AUTORENDER observation', 'author': '7AGENCY', 'version': (1, 0, 0), 'blender': (4, 0, 0), 'category': 'System'}
_SLOT = '_autoren_render_relay_v1'


def process_birth_token():
    """Windows GetProcessTimes creation FILETIME, decimal 100 ns ticks."""
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    creation, exit_time, kernel_time, user_time = (wintypes.FILETIME() for _ in range(4))
    if not kernel.GetProcessTimes(kernel.GetCurrentProcess(), ctypes.byref(creation), ctypes.byref(exit_time), ctypes.byref(kernel_time), ctypes.byref(user_time)):
        raise OSError('GetProcessTimes')
    return str((creation.dwHighDateTime << 32) | creation.dwLowDateTime)


class OutputManifest:
    """Append-only native paths, bounded pages; completeness is attested only on native end."""
    def __init__(self, root, state):
        self.root = root / state['invocationToken']
        self.state = state
        self.pending, self.pages, self.seen = [], [], set()
        self.failed = False

    def write(self, name, payload):
        if self.root.is_symlink() or any(p.is_symlink() for p in self.root.parents):
            raise RuntimeError('manifest-reparse')
        self.root.mkdir(parents=True, exist_ok=True)
        data = json.dumps(payload, ensure_ascii=True, separators=(',', ':')).encode()
        if len(data) > 524288:
            raise RuntimeError('manifest-page-bound')
        path = self.root / name
        with path.open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        return hashlib.sha256(data).hexdigest()

    def append(self, path, frame=None):
        try:
            normalized = str(path).replace('\\', '/').lower()
            if not (ntpath.isabs(path) or Path(path).is_absolute()) or '..' in normalized.split('/') or len(path.encode()) > 4096:
                raise RuntimeError('manifest-invalid-path')
            if normalized in self.seen:
                return
            if len(self.seen) >= 50000:
                raise RuntimeError('manifest-count-bound')
            self.seen.add(normalized)
            stamp = Path(path).stat()
            self.pending.append({'bytes': stamp.st_size, 'modifiedNanoseconds': stamp.st_mtime_ns, 'id': hashlib.sha256((self.state['invocationToken']+'|'+normalized).encode()).hexdigest(), 'path': path, 'frame': frame})
            if len(self.pending) >= 32:
                self.flush()
        except Exception:
            self.failed = True

    def flush(self):
        if not self.pending:
            return
        name = 'page-%06d.json' % len(self.pages)
        digest = self.write(name, {'schemaVersion': 1, 'id': self.state['invocationToken'], 'artifacts': self.pending})
        self.pages.append({'name': name, 'sha256': digest, 'count': len(self.pending)})
        self.pending = []

    def finish(self):
        try:
            self.flush()
            complete = not self.failed and bool(self.seen) and sum(p['count'] for p in self.pages) == len(self.seen)
            final_pages = []
            for number, page in enumerate(self.pages):
                prior = json.loads((self.root / page['name']).read_text())
                for artifact in prior['artifacts']:
                    file = Path(artifact['path'])
                    if file.is_symlink():
                        raise RuntimeError('manifest-output-reparse')
                    stamp = file.stat()
                    artifact['bytes'], artifact['modifiedNanoseconds'] = stamp.st_size, stamp.st_mtime_ns
                name = 'final-%06d.json' % number
                digest = self.write(name, prior)
                final_pages.append({'name': name, 'sha256': digest, 'count': len(prior['artifacts'])})
            self.pages = final_pages
            payload = {'schemaVersion': 1, 'id': self.state['invocationToken'], 'pid': self.state['pid'], 'birthToken': self.state['birthToken'],
                       'startedAt': self.state['startedAt'], 'completedAt': self.state['eventAt'], 'expectedCount': len(self.seen), 'complete': complete, 'pages': self.pages}
            digest = self.write('index.json', payload)
            return {'id': payload['id'], 'indexPath': str(self.root / 'index.json'), 'sha256': digest, 'expectedCount': len(self.seen), 'complete': complete}
        except Exception:
            self.failed = True
            return None


class Relay:
    def __init__(self, bpy, root, pid, birth_token, clock=time.time, monotonic=time.monotonic):
        self.bpy, self.root, self.pid, self.birth_token = bpy, Path(root), pid, birth_token
        self.clock, self.monotonic = clock, monotonic
        self.lock = threading.RLock()
        self.state = None
        self.recent_invocations = []
        self.driver_started_at = None
        self.frame_started = None
        self.frame_serial = self.post_serial = self.write_serial = 0
        self.callbacks = []
        self.timer = self.heartbeat
        self.export_scene = None
        self.export_guard = None
        self.output_manifest = None
        self.enabled = False

    def timestamp(self):
        return datetime.datetime.fromtimestamp(self.clock(), datetime.timezone.utc).isoformat()

    def publish(self, idle_running=None):
        if not self.state:
            if idle_running is None:
                return
            payload = {'schemaVersion': 1, 'pid': self.pid, 'birthToken': self.birth_token,
                       'state': 'unknown' if idle_running else 'idle', 'jobRunning': bool(idle_running),
                       'observedAt': self.timestamp(), 'recentInvocations': self.recent_invocations}
        else:
            self.state['observedAt'] = self.timestamp()
            payload = dict(self.state, recentInvocations=self.recent_invocations)
        data = json.dumps(payload, ensure_ascii=True, separators=(',', ':')).encode('utf-8')
        while len(data) > 8192 and self.recent_invocations:
            self.recent_invocations.pop(0)
            payload['recentInvocations'] = self.recent_invocations
            data = json.dumps(payload, ensure_ascii=True, separators=(',', ':')).encode('utf-8')
        # Optional context must never prevent an activity/idle heartbeat from being written.
        if len(data) > 8192 and isinstance(payload.get('sourceContext'), dict):
            for field in ('outputPath', 'filePath', 'sceneName'):
                payload['sourceContext'].pop(field, None)
                data = json.dumps(payload, ensure_ascii=True, separators=(',', ':')).encode('utf-8')
                if len(data) <= 8192:
                    break
        if len(data) > 8192:
            return
        # Fail closed for directory/file links; never follow an alternate target.
        if self.root.is_symlink() or any(p.is_symlink() for p in self.root.parents):
            return
        self.root.mkdir(parents=True, exist_ok=True)
        target = self.root / (str(self.pid) + '.json')
        if target.is_symlink():
            return
        temporary = self.root / (str(self.pid) + '.' + uuid.uuid4().hex + '.tmp')
        try:
            with temporary.open('xb') as stream:
                stream.write(data)
            os.replace(temporary, target)
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass

    def render_title(self, scene):
        # Called only from render_init, after startup RestrictBlend has ended.
        def clean(value, limit):
            return ''.join(c for c in str(value) if ord(c) >= 32 and ord(c) != 127).strip()[:limit]
        try:
            scene_name = clean(getattr(scene, 'name', 'Blender'), 80) or 'Blender'
        except Exception:
            scene_name = 'Blender'
        try:
            filename = ntpath.basename(str(getattr(self.bpy.data, 'filepath', '') or ''))
            filename = clean(filename, 160)
        except Exception:
            filename = ''
        return filename + ' · ' + scene_name if filename else scene_name

    def render_context(self, scene):
        # Facts only, read in native handlers. No scene/settings/result mutations or export.
        result = {'origin': 'nativeBlender'}
        try:
            path = str(self.bpy.data.filepath or '')
            if path and len(path.encode('utf-8')) <= 4096:
                result['filePath'] = path
        except Exception:
            pass
        try:
            name = str(scene.name)
            if name and len(name.encode('utf-8')) <= 256:
                result['sceneName'] = name
        except Exception:
            pass
        return result

    def library_policy(self, require_export=True):
        try:
            file = self.root.parent / 'LibraryPolicy.json'
            if file.is_symlink() or file.stat().st_size > 8192:
                return None
            policy = json.loads(file.read_text(encoding='utf-8'))
            if policy.get('schemaVersion') != 1 or policy.get('enabled') is not True or (require_export and policy.get('exportInMemory') is not True):
                return None
            activated = datetime.datetime.fromisoformat(policy['activatedAt'].replace('Z', '+00:00'))
            expires = datetime.datetime.fromisoformat(policy['expiresAt'].replace('Z', '+00:00'))
            return policy if activated.timestamp() <= self.clock() <= expires.timestamp() <= self.clock()+130 else None
        except Exception:
            return None

    def export_signature(self, scene):
        # Read-only snapshot of export-affecting settings. Curves require a dedicated recipe.
        fields = {'render': ('filepath', 'use_multiview'),
                  'image_settings': ('file_format', 'color_mode', 'color_depth', 'quality', 'compression', 'exr_codec', 'tiff_codec', 'views_format', 'color_management'),
                  'view_settings': ('view_transform', 'look', 'exposure', 'gamma', 'use_curve_mapping', 'view_settings'),
                  'display_settings': ('display_device',)}
        result = []
        for group, keys in fields.items():
            obj = scene.render.image_settings if group == 'image_settings' else getattr(scene, group, None)
            if group == 'render': obj = scene.render
            for key in keys:
                value = getattr(obj, key, None)
                if key == 'use_curve_mapping' and value:
                    raise RuntimeError('curve-export-needs-review')
                result.append((group, key, value if type(value) in (str, int, float, bool, type(None)) else str(value)))
        return result

    def export_render_result(self):
        # Called only by Blender's main-thread timer, after native completion and job idle.
        if not self.state or self.state['state'] != 'complete' or self.state['writtenFrames'] != 0 or self.state.get('exportState') != 'pending':
            return
        self.state['exportState'] = 'checking'
        temporary = None
        try:
            if threading.current_thread() is not threading.main_thread():
                raise RuntimeError('main-thread-GUI-required')
            policy = self.library_policy()
            if self.bpy.app.background and (not policy or policy.get('allowBackgroundExport') is not True):
                raise RuntimeError('background-export-not-opted-in')
            if not policy or policy.get('activatedAt') != self.state.get('libraryActivation'):
                raise RuntimeError('export-opt-in-no-longer-active')
            scene = self.export_scene
            guard = self.export_guard
            if not scene or not guard or self.bpy.app.is_job_running('RENDER'):
                raise RuntimeError('render-result-not-idle')
            image = self.bpy.data.images.get('Render Result')
            if not image or not image.has_data or image.type != 'RENDER_RESULT':
                raise RuntimeError('render-result-unavailable')
            before = (str(self.bpy.data.filepath), str(scene.render.filepath), str(scene.render.image_settings.file_format), str(image.filepath_raw))
            if scene.as_pointer() != guard['scene'] or scene.frame_current != guard['frame'] or before[0] != guard['file'] or before[2] != guard['format'] or self.export_signature(scene) != guard['signature']:
                raise RuntimeError('invocation-context-changed')
            if guard.get('resultPointer') != image.as_pointer():
                raise RuntimeError('render-result-replaced')
            if guard['slot'] is not None and image.render_slots.active_index != guard['slot']:
                raise RuntimeError('render-slot-changed')
            extensions = {'PNG': '.png', 'JPEG': '.jpg', 'OPEN_EXR': '.exr', 'OPEN_EXR_MULTILAYER': '.exr', 'TIFF': '.tif', 'WEBP': '.webp'}
            extension = extensions.get(before[2])
            if not extension or scene.render.use_multiview:
                raise RuntimeError('format-or-multiview-needs-review')
            estimated = int(image.size[0]) * int(image.size[1]) * max(1, int(image.channels)) * 4
            maximum = min(512*1024*1024, max(1, int(policy.get('maximumExportBytes', 128*1024*1024))))
            if estimated <= 0 or estimated > maximum:
                raise RuntimeError('export-size-bound')
            folder = self.root.parent / 'Outbox' / self.state['invocationToken']
            if folder.is_symlink() or any(p.is_symlink() for p in folder.parents):
                raise RuntimeError('outbox-reparse')
            folder.mkdir(parents=True, exist_ok=True)
            final = folder / ('render-result' + extension)
            if final.exists() or final.is_symlink():
                raise RuntimeError('outbox-collision')
            temporary = folder / ('.export-' + uuid.uuid4().hex + extension)
            # save_render uses the scene's actual image format; no format/settings assignment here.
            image.save_render(str(temporary), scene=scene)
            after = (str(self.bpy.data.filepath), str(scene.render.filepath), str(scene.render.image_settings.file_format), str(image.filepath_raw))
            if before != after or not temporary.is_file() or temporary.is_symlink() or not 0 < temporary.stat().st_size <= maximum:
                raise RuntimeError('export-settings-or-file-changed')
            digest = hashlib.sha256()
            with temporary.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024*1024), b''):
                    digest.update(chunk)
            with temporary.open('rb+') as durable:
                os.fsync(durable.fileno())
            os.link(temporary, final)  # Exclusive final name, never overwrite.
            self.state['exportArtifact'] = {'path': str(final), 'sha256': digest.hexdigest(), 'bytes': final.stat().st_size}
            self.state['sourceContext']['outputPath'] = str(final)
            if self.output_manifest:
                self.output_manifest.append(str(final), self.state.get('currentFrame'))
                self.state['outputManifest'] = self.output_manifest.finish()
            self.state['exportState'] = 'exported'
        except Exception as exc:
            self.state['exportState'] = 'inMemoryNeedsReview'
            self.state['exportReason'] = str(exc)[:120]
        finally:
            if temporary:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass

    def event(self, kind, scene):
        # Blender must never receive a monitoring exception, including disk/scene failures.
        try:
            with self.lock:
                if kind == 'init':
                    if self.state and self.state.get('exportState') == 'pending':
                        self.state['exportState'] = 'inMemoryReplacedBeforeExport'
                    if self.state and self.state['state'] in ('complete', 'cancel'):
                        self.recent_invocations.append(self.state.copy())
                        self.recent_invocations = self.recent_invocations[-8:]
                    if self.driver_started_at is None:
                        self.driver_started_at = self.timestamp()
                    self.state = {'schemaVersion': 1, 'pid': self.pid, 'birthToken': self.birth_token,
                                  'invocationToken': uuid.uuid4().hex, 'startedAt': self.timestamp(),
                                  'eventAt': self.timestamp(), 'driverStartedAt': self.driver_started_at, 'state': 'active', 'phase': 'init',
                                  'completedFrames': 0, 'writtenFrames': 0, 'durationsSeconds': [],
                                  'title': self.render_title(scene), 'sourceContext': self.render_context(scene), 'mode': 'unknown'}
                    self.export_scene = None
                    self.export_guard = None
                    policy = self.library_policy(require_export=False)
                    self.output_manifest = OutputManifest(self.root.parent / 'Manifests', self.state) if policy else None
                    if policy and policy.get('exportInMemory') is True and (not self.bpy.app.background or policy.get('allowBackgroundExport') is True):
                        try:
                            image = self.bpy.data.images.get('Render Result')
                            self.export_scene = scene
                            self.export_guard = {'scene': scene.as_pointer(), 'frame': scene.frame_current, 'file': str(self.bpy.data.filepath), 'format': str(scene.render.image_settings.file_format), 'slot': image.render_slots.active_index if image else None, 'signature': self.export_signature(scene)}
                            self.state['libraryActivation'] = policy['activatedAt']
                            self.state['exportState'] = 'eligible'
                        except Exception:
                            self.state['exportState'] = 'inMemoryNeedsReview'
                    self.frame_started = None
                    self.frame_serial = self.post_serial = self.write_serial = 0
                elif not self.state or self.state['state'] not in ('active', 'unknown'):
                    return
                frame = getattr(scene, 'frame_current', None)
                if type(frame) is int and -(2**31) <= frame < 2**31:
                    self.state['currentFrame'] = frame
                self.state['phase'] = kind
                self.state['eventAt'] = self.timestamp()
                if kind == 'pre':
                    self.state['state'] = 'active'
                    self.state.pop('jobRunning', None)
                    self.frame_serial += 1
                    self.frame_started = self.monotonic()
                elif kind == 'post' and self.post_serial < self.frame_serial:
                    self.post_serial = self.frame_serial
                    self.state['completedFrames'] = min(1_000_000, self.state['completedFrames'] + 1)
                    if self.frame_started is not None:
                        duration = self.monotonic() - self.frame_started
                        if 0 < duration <= 86400:
                            self.state['durationsSeconds'] = (self.state['durationsSeconds'] + [duration])[-16:]
                elif kind == 'write' and self.write_serial < self.frame_serial:
                    self.write_serial = self.frame_serial
                    self.state['writtenFrames'] = min(1_000_000, self.state['writtenFrames'] + 1)
                    try:
                        if not scene.render.use_multiview:
                            path = str(scene.render.frame_path(frame=scene.frame_current))
                            if path and len(path.encode('utf-8')) <= 4096:
                                self.state['sourceContext']['outputPath'] = path
                                if self.output_manifest:
                                    self.output_manifest.append(path, scene.frame_current)
                    except Exception:
                        pass
                elif kind in ('complete', 'cancel'):
                    self.state['state'] = kind
                    if kind == 'complete' and self.state['writtenFrames'] > 0 and self.output_manifest:
                        self.state['outputManifest'] = self.output_manifest.finish()
                    if kind == 'complete' and self.state['writtenFrames'] == 0 and self.state.get('exportState') == 'eligible':
                        try:
                            image = self.bpy.data.images.get('Render Result')
                            self.export_guard['resultPointer'] = image.as_pointer()
                            if self.export_guard['slot'] is None:
                                self.export_guard['slot'] = image.render_slots.active_index
                            self.state['exportState'] = 'pending'
                        except Exception:
                            self.state['exportState'] = 'inMemoryNeedsReview'
                self.publish()
        except Exception:
            pass

    def heartbeat(self):
        if not self.enabled:
            return None
        running = None
        try:
            with self.lock:
                running = bool(self.bpy.app.is_job_running('RENDER'))
                if self.state:
                    self.state['jobRunning'] = running
                    if self.state['state'] == 'unknown' and running:
                        self.state['state'] = 'active'
                    if self.state['state'] == 'active' and not running:
                        # Missing complete/cancel event proves neither result. Never infer completion.
                        self.state['state'] = 'unknown'
                    if not running:
                        self.export_render_result()
                    self.publish()
                else:
                    self.publish(idle_running=running)
        except Exception:
            pass
        if not self.state:
            return 2.0 if running else 10.0
        if self.state['state'] in ('complete', 'cancel'):
            return 10.0
        return 2.0 if self.state['state'] == 'active' else 5.0

    def register(self):
        if self.enabled:
            return
        self.enabled = True
        try:
            for kind in ('init', 'pre', 'post', 'write', 'complete', 'cancel'):
                def callback(scene, *unused, _kind=kind):
                    self.event(_kind, scene)
                callback = self.bpy.app.handlers.persistent(callback)
                handlers = getattr(self.bpy.app.handlers, 'render_' + kind)
                handlers.append(callback)
                self.callbacks.append((handlers, callback))
            self.bpy.app.timers.register(self.timer, first_interval=2.0, persistent=True)
        except Exception:
            self.unregister()

    def unregister(self):
        self.enabled = False
        for handlers, callback in self.callbacks:
            try:
                if callback in handlers:
                    handlers.remove(callback)
            except Exception:
                pass
        self.callbacks = []
        try:
            if self.bpy.app.timers.is_registered(self.timer):
                self.bpy.app.timers.unregister(self.timer)
        except Exception:
            pass
        try:
            if not self.state:
                self.publish(idle_running=True)
            elif self.state['state'] == 'active':
                self.state['state'] = 'unknown'
                self.publish()
        except Exception:
            pass


def register():
    try:
        if os.name != 'nt':
            return
        import bpy
        previous = getattr(bpy, _SLOT, None)
        if previous:
            previous.unregister()
        local = os.environ.get('LOCALAPPDATA')
        if not local or not Path(local).is_absolute():
            return
        relay = Relay(bpy, Path(local) / 'AUTORENDER' / 'Blender', os.getpid(), process_birth_token())
        setattr(bpy, _SLOT, relay)
        relay.register()
    except Exception:
        pass


def unregister():
    try:
        import bpy
        relay = getattr(bpy, _SLOT, None)
        if relay:
            relay.unregister()
            delattr(bpy, _SLOT)
    except Exception:
        pass
