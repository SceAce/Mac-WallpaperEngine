#!/usr/bin/env python3
"""Integration checks against a running development app with an isolated --config."""
import argparse
import json
import pathlib
import time
import tempfile
import urllib.request
import urllib.error

parser = argparse.ArgumentParser()
parser.add_argument('url')
parser.add_argument('library', type=pathlib.Path)
parser.add_argument('--videos', action='store_true')
args = parser.parse_args()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path, payload=None, error=False):
    req = urllib.request.Request(args.url + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'})
    try:
        with opener.open(req, timeout=45) as response:
            result = json.load(response)
    except urllib.error.HTTPError as failure:
        result = json.load(failure)
        if not error:
            raise AssertionError(result)
    assert bool(result.get('ok')) != error, result
    return result


def state():
    return request('/api/state')['control']['payload']


def select(path, error=False):
    return request('/api/wallpaper/select', {'projectPath': str(path)}, error=error)


projects = request('/api/projects')['projects']
assert len(projects) >= 54
video = args.library / '2519042412'
select(video)
request('/api/config', {'playing': True, 'mute': True, 'volume': 35, 'content-fit': 2, 'scene-fps': 30})
time.sleep(1)
first = state()['outputs'][0]['playbackTime']
time.sleep(0.6)
assert state()['outputs'][0]['playbackTime'] > first
request('/api/config', {'playing': False})
time.sleep(0.2)
first = state()['outputs'][0]['playbackTime']
time.sleep(0.6)
assert abs(state()['outputs'][0]['playbackTime'] - first) < 0.02
request('/api/config', {'playing': True})
for path in [args.library / '3265572285', args.library / 'missing-video']:
    before = state()['global']
    select(path, error=True)
    assert state()['global'] == before
    assert state()['outputs'][0]['status'] == 'playing'
# Exercise asynchronous decoder failure, not just preflight path validation.
with tempfile.TemporaryDirectory(prefix='vivid-invalid-video-') as temporary:
    broken = pathlib.Path(temporary)
    (broken / 'project.json').write_text(json.dumps({'type': 'video', 'file': 'broken.mp4'}))
    (broken / 'broken.mp4').write_bytes(b'not a media file')
    before = state()['global']
    select(broken, error=True)
    assert state()['global'] == before
    assert state()['outputs'][0]['status'] == 'playing'
request('/api/config', {'scene-fps': 0}, error=True)
request('/api/config', {'gfx-shadows': 99}, error=True)
assert state()['global']['scene-fps'] == 30
if args.videos:
    for project in projects:
        if project['type'] != 'video':
            continue
        select(project['path'])
        time.sleep(0.5)
        assert state()['outputs'][0]['playbackTime'] > 0
        print('PASS video', pathlib.Path(project['path']).name, project['title'], flush=True)
select(args.library / '3220055919')
time.sleep(1)
first = state()['outputs'][0]['completedFrames']
time.sleep(0.6)
assert state()['outputs'][0]['completedFrames'] > first
request('/api/config', {'playing': False})
time.sleep(0.3)
first = state()['outputs'][0]['completedFrames']
time.sleep(0.6)
assert state()['outputs'][0]['completedFrames'] <= first + 1
request('/api/config', {'playing': True, 'scene-fps': 20, 'content-fit': 1})
select(video)
print('PASS panel catalog, video/scene switching, pause/resume, settings and failed-selection rollback', flush=True)
