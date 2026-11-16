"""look never leaves the AI waiting for minutes: the isolated test App (run.sh) and the real skycut-mcp helper, two AI sessions.

docs/bugfixes/2026-11-17-look-hangs-and-dropped-calls.md. Checks what CI cannot (the router behind the license gate):
1. two sessions each send two 12-frame looks at once: every look answers within 30 s with its picture, or with a job_id whose
   get_job brings the picture; nothing is dropped;
2. an edit sent right behind a look on the same project answers before the look;
3. two looks sent behind a long edit_clips (fit=fill on every clip) answer as queued jobs (queue_position 1 and 2, waiting_for names
   edit_clips) when the edit takes longer than 25 s; cancel_job cancels the second; get_job brings the first's picture.
Footage: synthetic one-keyframe clips made here. Projects are closed at the end.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts/gui-smoke'))
from mcpclient import MCP

ROOT = Path(os.environ.get('SKYSTUDIO_SMOKE_DIR', '/private/tmp/srtflow-skystudio-smoke'))
HELPER = str(ROOT / 'SrtFlowSkyStudioSmoke.app/Contents/Helpers/skycut-mcp')
MEDIA = ROOT / 'work' / 'look-jobs'
FFMPEG = os.environ.get('SRTFLOW_FFMPEG', str(REPO / 'vendor/ffmpeg'))
failures = []


def check(condition, message):
    print(('ok   ' if condition else 'FAIL ') + message, flush=True)
    if not condition:
        failures.append(message)


def call(mcp, name, args, timeout=200):
    started = time.monotonic()
    result = mcp.request('tools/call', {'name': name, 'arguments': args}, timeout=timeout)['result']
    text = next((c['text'] for c in result.get('content', []) if c.get('type') == 'text'), '')
    try:
        value = json.loads(text)
    except ValueError:
        value = text
    images = sum(1 for c in result.get('content', []) if c.get('type') == 'image')
    return {'value': value, 'images': images, 'seconds': round(time.monotonic() - started, 2), 'error': bool(result.get('isError'))}


def picture(mcp, answer):
    """The look's picture: directly, or through get_job when the look became a job."""
    value = answer['value']
    if not (isinstance(value, dict) and value.get('job_id')):
        return answer['images'] == 1 and not answer['error']
    while True:
        row = call(mcp, 'get_job', {'job_id': value['job_id'], 'wait_seconds': 30})
        if row['value'].get('status') in ('done', 'failed', 'cancelled'):
            return row['value']['status'] == 'done' and row['images'] == 1 and len(row['value']['result']['frames']) == 12


def at_once(jobs):
    results = [None] * len(jobs)
    def run(index, mcp, name, args, delay):
        time.sleep(delay)
        results[index] = call(mcp, name, args)
    threads = [threading.Thread(target=run, args=(i, *job)) for i, job in enumerate(jobs)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results


def twelve(start):
    return [round(start + i * 0.17, 2) for i in range(12)]


MEDIA.mkdir(parents=True, exist_ok=True)
# Mixed shapes (the first sets the 16:9 canvas): fit=fill has to find the subject in the other two, as with real footage.
for name, size in (('testsrc2', '1920x1080'), ('smptehdbars', '1440x1080'), ('mandelbrot', '1080x1350')):
    target = MEDIA / f'{name}.mp4'
    if not target.exists():
        subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-nostdin', '-f', 'lavfi', '-i', f'{name}=size={size}:rate=24',
                        '-t', '6.5', '-c:v', 'libx264', '-preset', 'veryfast', '-g', '1000', '-keyint_min', '1000', '-sc_threshold', '0',
                        '-pix_fmt', 'yuv420p', str(target)], check=True, timeout=120)
files = sorted(p.name for p in MEDIA.glob('*.mp4'))
sessions, projects, clip_ids = [MCP(HELPER, env={**os.environ, 'SRTFLOW_MCP_NO_LAUNCH': '1'}) for _ in range(2)], [], []
try:
    for index, mcp in enumerate(sessions):
        call(mcp, 'open_folder', {'path': str(MEDIA)})
        call(mcp, 'set_view', {'mode': 'background'})
        created = call(mcp, 'new_project', {'folder': str(MEDIA), 'name': f'Look jobs {index}', 'version': time.strftime('%H%M%S')})
        projects.append(created['value']['project'])
        clips = [{'file': files[i % len(files)], 'source_in': 0.2, 'source_out': 6.2, 'start': i * 6.0, 'track': 'V1'} for i in range(30)]
        added = call(mcp, 'add_clips', {'project': projects[-1], 'clips': clips})
        check(not added['error'], f'session {index}: 30 clips on V1')
        clip_ids.append([item['id'] for item in added['value']['added']])
    a, b = sessions
    pa, pb = projects
    looks = at_once([(a, 'look', {'project': pa, 'times': twelve(10)}, 0), (a, 'look', {'project': pa, 'times': twelve(70)}, 0.05),
                     (b, 'look', {'project': pb, 'times': twelve(10)}, 0.1), (b, 'look', {'project': pb, 'times': twelve(70)}, 0.15)])
    for index, answer in enumerate(looks):
        check(answer['seconds'] < 30, f'look {index + 1} of 4 answered in {answer["seconds"]} s')
        check(picture(a if index < 2 else b, answer), f'look {index + 1} of 4 brought its picture (directly or with get_job)')
    look, edit = at_once([(a, 'look', {'project': pa, 'times': twelve(30)}, 0), (a, 'set_track', {'project': pa, 'track': 'V1', 'hidden': False}, 0.1)])
    check(edit['seconds'] < look['seconds'], f'an edit behind a look answered first ({edit["seconds"]} s, the look {look["seconds"]} s)')
    long_edit = [{'clip_id': clip, 'fit': 'fill', 'focus': 'subject'} for clip in clip_ids[0]]
    results = {}
    def run(key, name, args, delay):
        time.sleep(delay)
        results[key] = call(a, name, args)
    jobs = {'edit': ('edit_clips', {'project': pa, 'clips': long_edit}, 0), 'first': ('look', {'project': pa, 'times': twelve(40)}, 1.0),
            'second': ('look', {'project': pa, 'times': twelve(90)}, 1.2)}
    threads = {key: threading.Thread(target=run, args=(key, *job)) for key, job in jobs.items()}
    for thread in threads.values():
        thread.start()
    threads['first'].join()
    threads['second'].join()
    first, second = results['first'], results['second']
    edit_running = threads['edit'].is_alive()
    if isinstance(first['value'], dict) and first['value'].get('job_id'):
        check(first['value'].get('status') == 'queued' and first['value'].get('queue_position') == 1
              and str(first['value'].get('waiting_for', '')).startswith('edit_clips from this AI session'), f'first look queued behind edit_clips: {first["value"]}')
        check(second['value'].get('queue_position') == 2, f'second look second in line: {second["value"]}')
        cancelled = call(a, 'cancel_job', {'job_id': second['value']['job_id']})['value']
        if edit_running and threads['edit'].is_alive():
            check(cancelled.get('status') == 'cancelled' and 'never started' in cancelled.get('message', ''),
                  f'the second look, cancelled while the edit still ran, never started: {cancelled.get("message")}')
        else:
            check(cancelled.get('status') == 'cancelled', f'the second look cancelled: {cancelled.get("message")}')
    else:
        print('edit_clips ended within 25 s on this Mac: the queued case was not exercised here (scripts/check-look-jobs.sh covers it)')
    threads['edit'].join()
    edit = results['edit']
    print(f'edit_clips took {edit["seconds"]} s; the looks answered after {first["seconds"]} s and {second["seconds"]} s', flush=True)
    check(not edit['error'], f'edit_clips fit=fill went through: {str(edit["value"])[:200]}')
    check(picture(a, first), 'the look behind the edit brought its picture')
finally:
    for mcp, project in zip(sessions, projects):
        try:
            call(mcp, 'close_project', {'project': project})
        except Exception as error:  # noqa: BLE001 - report, keep closing
            print(f'close_project {project}: {error}')
    for mcp in sessions:
        mcp.close()
print('PASS: look jobs smoke' if not failures else f'FAIL: {len(failures)} look jobs smoke checks')
sys.exit(1 if failures else 0)
