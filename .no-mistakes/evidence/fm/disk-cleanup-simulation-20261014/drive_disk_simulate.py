#!/usr/bin/env python3
"""Live end-to-end driver for the fm-disk-simulate-* product surface.

Runs the real entry points from the worktree against isolated isolated layouts
under a temp root. Every case drives the shipped script and asserts the emitted
JSONL decision/reasons plus on-disk non-mutation.

Output is a reproducible transcript (stdout) that doubles as run evidence.
"""
import datetime
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

WORKTREE = Path(os.environ['FM_WORKTREE'])
# /tmp is a symlink to /private/tmp on macOS; the evaluator refuses symlinked
# ancestors, so the harness must hand it canonical paths.
TMP = Path(tempfile.mkdtemp(prefix='fm-disk-sim-live.', dir='/tmp')).resolve()
LAYOUT = TMP / 'layout'
LAYOUT.mkdir()

RESULTS = []


def log(msg):
    print(msg, flush=True)


def entry(machine):
    return str(WORKTREE / 'bin' / ('fm-disk-simulate-' + machine + '.sh'))


def snapshot(machine, objects, env=None):
    observed = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return {'schema': 1, 'machine': machine, 'provenance': {
        'kind': 'local', 'source': 'live isolated layout ' + str(LAYOUT),
        'observed_at': observed}, 'objects': objects}


def run(machine, value=None, flags=(), env=None, raw_args=None):
    args = ['bash', entry(machine)]
    if value is not None:
        inv = TMP / 'inventory.json'
        inv.write_text(json.dumps(value))
        args += ['--inventory', str(inv)]
    if raw_args is not None:
        args = ['bash', entry(machine)] + list(raw_args)
    environment = dict(os.environ)
    environment.pop('FM_HOME', None)
    environment.pop('FM_ROOT_OVERRIDE', None)
    environment.pop('FM_DATA_OVERRIDE', None)
    environment.pop('FM_STATE_OVERRIDE', None)
    for key, val in (env or {}).items():
        if val is None:
            environment.pop(key, None)
        else:
            environment[key] = val
    result = subprocess.run(args, text=True, capture_output=True, env=environment)
    rows = []
    for line in result.stdout.splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return result, rows


def check(name, condition, detail=''):
    RESULTS.append((name, bool(condition)))
    log(('PASS ' if condition else 'FAIL ') + name + (('  :: ' + detail) if detail else ''))
    return bool(condition)


def rec(argv, stdout='', exit=0, stderr=''):
    return {'argv': argv, 'stdout': stdout, 'exit': exit, 'stderr': stderr}


def supplied_evidence(path, *, uid, processes='    1     0 /sbin/init\n'):
    return {
        'identity': rec(['id', '-u'], '0\n'),
        'processes': rec(['ps', '-axo', 'pid=,uid=,comm='], processes),
        'open-files': rec(['lsof', '-nP', '+D', str(path)], exit=1),
    }


def git_record(args):
    command = args
    result = subprocess.run(command, text=True, capture_output=True)
    return {'argv': command, 'exit': result.returncode,
            'stdout': result.stdout, 'stderr': result.stderr}


# ---------------------------------------------------------------------------
# Case A: staging approved old-build snapshot -> candidate + line 60, no delete
# ---------------------------------------------------------------------------
log('== Case A: staging approved named old release is proposed, never deleted')
releases = LAYOUT / 'releases'
for name in ('old', 'current', 'rollback'):
    (releases / name).mkdir(parents=True)
marker = releases / 'old' / 'build-output.txt'
marker.write_text('must survive')
current_link = LAYOUT / 'current'
rollback_link = LAYOUT / 'last-rollback'
current_link.symlink_to(releases / 'current', target_is_directory=True)
rollback_link.symlink_to(releases / 'rollback', target_is_directory=True)
build = {'path': str(releases / 'old'), 'kind': 'old-build',
         'owner_uid': (releases / 'old').stat().st_uid,
         'release_root': str(releases), 'current_link': str(current_link),
         'rollback_link': str(rollback_link),
         'evidence': supplied_evidence(releases / 'old', uid=501)}
result, rows = run('staging', snapshot('staging', [build]))
check('A1 staging candidate exit 0', result.returncode == 0, f'rc={result.returncode} stdout={result.stdout.strip()}')
check('A2 staging candidate decision', rows and rows[0]['decision'] == 'candidate', json.dumps(rows[:1]))
check('A3 staging candidate carries section 3 line 60',
      rows and rows[0]['whitelist'] == {'id': 'staging.old-build', 'section': 3,
                                        'report_line': 60,
                                        'line': 'anciens builds hors release courante et dernier rollback'},
      json.dumps(rows[:1]))
check('A4 simulation_only flag present', rows and rows[0]['simulation_only'] is True)
check('A5 candidate directory untouched after evaluation',
      marker.read_text() == 'must survive' and (releases / 'current').is_dir())
log('    row: ' + json.dumps(rows[0], sort_keys=True))

# ---------------------------------------------------------------------------
# Case B: imac task-artifact with genuinely live git observations -> candidate
# ---------------------------------------------------------------------------
log('== Case B: imac end-of-task artifact on a real pushed+landed git repo')
repo = LAYOUT / 'repo'
subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
subprocess.run(['git', '-C', str(repo), 'config', 'user.email', 'sim@example.test'], check=True)
subprocess.run(['git', '-C', str(repo), 'config', 'user.name', 'Sim'], check=True)
(repo / 'tracked.txt').write_text('base')
subprocess.run(['git', '-C', str(repo), 'add', 'tracked.txt'], check=True)
subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'base'], check=True)
remote = LAYOUT / 'origin.git'
subprocess.run(['git', 'clone', '--bare', '-q', str(repo), str(remote)], check=True)
subprocess.run(['git', '-C', str(repo), 'remote', 'add', 'origin', str(remote)], check=True)
subprocess.run(['git', '-C', str(repo), 'push', '-q', '-u', 'origin', 'main'], check=True)
subprocess.run(['git', '-C', str(repo), 'fetch', '-q', 'origin'], check=True)
subprocess.run(['git', '-C', str(repo), 'symbolic-ref', 'refs/remotes/origin/HEAD',
                'refs/remotes/origin/main'], check=True)
sha = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
branch_ref = 'refs/remotes/origin/main'
artifact = repo / 'build-output'
artifact.mkdir()
status_file = TMP / 'task.status'
meta_file = TMP / 'task.meta'
status_file.write_text('done: local validation complete\n')
meta_file.write_text('worktree=' + str(repo) + '\nkind=ship\n')
item = {'path': str(artifact), 'kind': 'task-artifact',
        'owner_uid': artifact.stat().st_uid,
        'repository_root': str(repo), 'pool_root': str(LAYOUT),
        'landed_ref': sha, 'landing_branch': branch_ref,
        'task_status_path': str(status_file), 'task_meta_path': str(meta_file),
        'evidence': supplied_evidence(artifact, uid=501)}
item['evidence'].update({
    'git-status': git_record(['git', '-C', str(repo), 'status', '--porcelain=v1', '--untracked-files=all']),
    'git-pushed': git_record(['git', '-C', str(repo), 'rev-list', '--count', '@{upstream}..HEAD']),
    'git-landed': git_record(['git', '-C', str(repo), 'merge-base', '--is-ancestor', 'HEAD', sha]),
    'git-default-branch': git_record(['git', '-C', str(repo), 'symbolic-ref', 'refs/remotes/origin/HEAD']),
    'git-landing-sha': git_record(['git', '-C', str(repo), 'rev-parse', '--verify', branch_ref + '^{commit}']),
    'treehouse': rec(['treehouse', 'status', '--json', '--root', str(LAYOUT)], json.dumps([{
        'name': 'sim', 'path': str(repo), 'status': 'available', 'branch': 'main',
        'lease_id': '', 'lease_holder': '', 'leased_at': None, 'processes': []}])),
    'task-status': git_record(['cat', str(status_file)]),
    'task-meta': git_record(['cat', str(meta_file)]),
})
result, rows = run('imac', snapshot('imac', [item]))
case_b_evidence = json.loads(json.dumps(item['evidence']))
check('B1 imac task-artifact candidate on real landed repo', result.returncode == 0 and rows
      and rows[0]['decision'] == 'candidate', json.dumps(rows[:1]))
check('B2 imac candidate carries section 3 line 54',
      rows and rows[0]['whitelist']['report_line'] == 54, json.dumps(rows[:1]))
# B3: create a second commit that is not pushed -> candidate must refuse
(repo / 'tracked.txt').write_text('unpushed change')
subprocess.run(['git', '-C', str(repo), 'add', 'tracked.txt'], check=True)
subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'unpushed'], check=True)
item['evidence']['git-status'] = git_record(['git', '-C', str(repo), 'status', '--porcelain=v1', '--untracked-files=all'])
item['evidence']['git-pushed'] = git_record(['git', '-C', str(repo), 'rev-list', '--count', '@{upstream}..HEAD'])
result, rows = run('imac', snapshot('imac', [item]))
check('B3 unpushed work refuses', result.returncode == 2 and 'unpushed-work' in rows[0]['reasons'],
      json.dumps(rows[:1]))
# restore pushed state for later cases
subprocess.run(['git', '-C', str(repo), 'reset', '-q', '--hard', 'origin/main'], check=True)

# ---------------------------------------------------------------------------
# Case C: FT has no whitelist/inventory authority and always refuses
# ---------------------------------------------------------------------------
log('== Case C: FT always refuses candidate evaluation')
result, rows = run('ft', snapshot('imac', [{'path': str(LAYOUT), 'kind': 'worktree', 'evidence': {}}]))
check('C1 FT refuses foreign inventory', result.returncode == 2 and rows
      and rows[0]['decision'] == 'refused' and rows[0]['whitelist'] is None
      and 'missing-whitelist' in rows[0]['reasons'], json.dumps(rows[:1]))
result, rows = run('ft', raw_args=[])
check('C2 FT refuses even with no inventory', result.returncode == 2 and rows
      and rows[0]['decision'] == 'refused', json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case D: destructive/discovery flags refuse and delete nothing
# ---------------------------------------------------------------------------
log('== Case D: destructive and discovery-style arguments refuse')
for flag in ('--apply', '--delete', '--prune', '--archive', '--yes', '--force'):
    result, rows = run('imac', raw_args=(flag,))
    check(f'D {flag} refuses', result.returncode == 2 and rows
          and 'unsupported-arguments' in rows[0]['reasons'], f'{flag} -> {result.stdout.strip()}')
check('D-nomutation file still present', marker.read_text() == 'must survive')

# ---------------------------------------------------------------------------
# Case E: effective FM_HOME / override data-state exclusion (round-6 surface)
# ---------------------------------------------------------------------------
log('== Case E: private home data/state excluded via effective FM_HOME and overrides')
effective = LAYOUT / 'effective-home'
(effective / 'data' / 'old').mkdir(parents=True)
(effective / 'state' / 'old').mkdir(parents=True)
override_data = LAYOUT / 'override-data'
(override_data / 'old').mkdir(parents=True)
alias = LAYOUT / 'home-alias'
alias.symlink_to(effective, target_is_directory=True)
home_cases = (
    ('FM_HOME data', effective / 'data' / 'old', {'FM_HOME': str(effective)}),
    ('FM_HOME state', effective / 'state' / 'old', {'FM_HOME': str(effective)}),
    ('FM_ROOT_OVERRIDE data', effective / 'data' / 'old',
     {'FM_HOME': None, 'FM_ROOT_OVERRIDE': str(effective)}),
    ('FM_DATA_OVERRIDE data', override_data / 'old',
     {'FM_HOME': str(effective), 'FM_DATA_OVERRIDE': str(override_data)}),
    ('alias spelling through symlinked FM_HOME', alias / 'data' / 'old',
     {'FM_HOME': str(effective)}),
)
for label, candidate, env in home_cases:
    result, rows = run('imac', snapshot('imac', [
        {'path': str(candidate), 'kind': 'task-artifact', 'evidence': {}}]), env=env)
    check(f'E excluded-path: {label}', result.returncode == 2 and rows
          and 'excluded-path' in rows[0]['reasons'], f'{label} -> {result.stdout.strip()}')

# ---------------------------------------------------------------------------
# Case F: real descendant exclusion + symlink escape (live traversal)
# ---------------------------------------------------------------------------
log('== Case F: protected descendants and symlink escapes refuse on real trees')
holder = LAYOUT / 'scratch-holder'
(holder / 'backups').mkdir(parents=True)
(holder / 'backups' / 'kept').write_text('keep')
result, rows = run('imac', snapshot('imac', [{'path': str(holder), 'kind': 'task-artifact', 'evidence': {}}]))
check('F1 protected descendant backups/ refuses', result.returncode == 2 and rows
      and 'excluded-descendant' in rows[0]['reasons'], json.dumps(rows[:1]))
shutil.rmtree(holder / 'backups')
(holder / 'ms-playwright').mkdir()
result, rows = run('imac', snapshot('imac', [{'path': str(holder), 'kind': 'task-artifact', 'evidence': {}}]))
check('F2 ms-playwright descendant refuses', result.returncode == 2 and rows
      and 'excluded-descendant' in rows[0]['reasons'], json.dumps(rows[:1]))
shutil.rmtree(holder / 'ms-playwright')
escape = LAYOUT / 'apparently-safe'
escape.symlink_to(LAYOUT / 'effective-home', target_is_directory=True)
result, rows = run('imac', snapshot('imac', [{'path': str(escape), 'kind': 'task-artifact', 'evidence': {}}]))
check('F3 symlinked object boundary refuses', result.returncode == 2 and rows
      and 'symlink-boundary' in rows[0]['reasons'], json.dumps(rows[:1]))
inner = LAYOUT / 'inner-escape'
inner.mkdir()
(inner / 'link-out').symlink_to(LAYOUT / 'effective-home', target_is_directory=True)
result, rows = run('imac', snapshot('imac', [{'path': str(inner), 'kind': 'task-artifact', 'evidence': {}}]))
check('F4 symlinked descendant refuses', result.returncode == 2 and rows
      and 'symlink-descendant' in rows[0]['reasons'], json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case G: regular non-directory object refuses (object-type boundary)
# ---------------------------------------------------------------------------
log('== Case G: regular-file object refuses as unsupported-object-type')
regular = LAYOUT / 'regular-object'
regular.write_text('not a directory')
result, rows = run('imac', snapshot('imac', [{'path': str(regular), 'kind': 'task-artifact', 'evidence': {}}]))
check('G1 regular file refuses explicitly', result.returncode == 2 and rows
      and 'unsupported-object-type' in rows[0]['reasons']
      and 'incomplete-native-evidence' not in rows[0]['reasons'], json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case H: genuinely live host observations cannot forge a candidate
# ---------------------------------------------------------------------------
log('== Case H: real non-root host observations refuse (no privileged proof)')
live_build = dict(build)
live_build['evidence'] = {
    'identity': git_record(['id', '-u']),
    'processes': git_record(['ps', '-axo', 'pid=,uid=,comm=']),
    'open-files': git_record(['lsof', '-nP', '+D', str(releases / 'old')]),
}
result, rows = run('staging', snapshot('staging', [live_build]))
check('H1 real host evidence cannot produce a candidate',
      result.returncode == 2 and rows and rows[0]['decision'] == 'refused'
      and ('incomplete-usage-privileges' in rows[0]['reasons']
           or 'active-shared-worker-or-tool' in rows[0]['reasons']), json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case I: VPS journal/tmp never invent retention proof
# ---------------------------------------------------------------------------
log('== Case I: VPS journal/tmp refuse without native-retention proof')
vpsobj = LAYOUT / 'var-log'
vpsobj.mkdir()
for kind in ('journal', 'temporary-file'):
    item = {'path': str(vpsobj), 'kind': kind, 'owner_uid': vpsobj.stat().st_uid,
            'evidence': supplied_evidence(vpsobj, uid=501)}
    result, rows = run('vps', snapshot('vps', [item]))
    check(f'I {kind} refuses native-retention-eligibility-unproven',
          result.returncode == 2 and rows
          and 'native-retention-eligibility-unproven' in rows[0]['reasons']
          and rows[0]['whitelist'] is not None, json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case J: Docker image referenced by a stopped container refuses
# ---------------------------------------------------------------------------
log('== Case J: Docker image referenced by a stopped container refuses')
image_id = 'sha256:' + 'a' * 64
container_id = 'b' * 64
image = {'path': image_id, 'kind': 'docker-image', 'evidence': {
    'identity': rec(['id', '-u'], '0\n'),
    'processes': rec(['ps', '-axo', 'pid=,uid=,comm='], '    1     0 /sbin/init\n'),
    'image-owner': rec(['stat', '-c', '%u', '/var/run/docker.sock'], '0\n'),
    'image': rec(['docker', 'image', 'inspect', image_id], json.dumps([{'Id': image_id}])),
    'containers': rec(['docker', 'container', 'ls', '-aq', '--no-trunc'], '')}}
result, rows = run('vps', snapshot('vps', [image]))
check('J1 unreferenced image candidate line 59', result.returncode == 0 and rows
      and rows[0]['decision'] == 'candidate' and rows[0]['whitelist']['report_line'] == 59,
      json.dumps(rows[:1]))
image['evidence']['containers'] = rec(['docker', 'container', 'ls', '-aq', '--no-trunc'], container_id + '\n')
image['evidence']['container-inspect'] = rec(
    ['docker', 'container', 'inspect', container_id],
    json.dumps([{'Id': container_id, 'Image': image_id, 'State': {'Running': False}}]))
result, rows = run('vps', snapshot('vps', [image]))
check('J2 stopped-container reference refuses', result.returncode == 2 and rows
      and 'image-referenced-by-container' in rows[0]['reasons'], json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case K: simulator availability boundary + intrinsic data/ child
# ---------------------------------------------------------------------------
log('== Case K: simulator candidacy and booted refusal')
udid = '12345678-1234-1234-1234-123456789ABC'
device = LAYOUT / 'Library' / 'Developer' / 'CoreSimulator' / 'Devices' / udid
(device / 'data').mkdir(parents=True)
(device / 'device.plist').write_text('device')
sim = {'path': str(device), 'kind': 'simulator', 'udid': udid,
       'owner_uid': device.stat().st_uid,
       'evidence': supplied_evidence(device, uid=501)}
devices = {'devices': {'runtime': [{'udid': udid, 'isAvailable': False, 'state': 'Shutdown'}]}}
sim['evidence']['simulators'] = rec(['xcrun', 'simctl', 'list', 'devices', '--json'], json.dumps(devices))
result, rows = run('imac', snapshot('imac', [sim]))
check('K1 unavailable+Shutdown simulator is proposed (intrinsic data/ allowed)',
      result.returncode == 0 and rows and rows[0]['decision'] == 'candidate'
      and rows[0]['whitelist']['report_line'] == 56, json.dumps(rows[:1]))
devices['devices']['runtime'][0]['state'] = 'Booted'
sim['evidence']['simulators'] = rec(['xcrun', 'simctl', 'list', 'devices', '--json'], json.dumps(devices))
result, rows = run('imac', snapshot('imac', [sim]))
check('K2 booted simulator refuses despite unavailable flag missing/available',
      result.returncode == 2 and rows
      and 'available-active-or-unknown-simulator' in rows[0]['reasons'], json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case L: stale/empty/mismatched inventory
# ---------------------------------------------------------------------------
log('== Case L: stale, empty and mismatched inventory refuse')
stale = snapshot('staging', [build])
stale['provenance']['observed_at'] = '2000-01-01T00:00:00+00:00'
result, rows = run('staging', stale)
check('L1 stale inventory refuses', result.returncode == 2 and rows
      and 'stale-inventory' in rows[0]['reasons'], json.dumps(rows[:1]))
result, rows = run('imac', snapshot('imac', []))
check('L2 empty inventory refuses', result.returncode == 2 and rows
      and 'empty-inventory' in rows[0]['reasons'], json.dumps(rows[:1]))
result, rows = run('staging', snapshot('imac', [build]))
check('L3 machine mismatch refuses', result.returncode == 2 and rows
      and 'machine-mismatch' in rows[0]['reasons'], json.dumps(rows[:1]))
result, rows = run('imac', None, raw_args=())
check('L4 missing inventory refuses explicitly', result.returncode == 2 and rows
      and 'missing-inventory' in rows[0]['reasons'], json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case M: imported argv is data, never executed
# ---------------------------------------------------------------------------
log('== Case M: imported argv is never executed')
sentinel = TMP / 'must-not-be-created'
build_m = json.loads(json.dumps(build))
build_m['evidence']['identity'] = rec(['touch', str(sentinel)], '0\n')
result, rows = run('staging', snapshot('staging', [build_m]))
check('M1 injected argv not executed', result.returncode == 2 and not sentinel.exists(),
      json.dumps(rows[:1]))

# ---------------------------------------------------------------------------
# Case N: named private/shared/backup/StorageBox/audio exclusions
# ---------------------------------------------------------------------------
log('== Case N: named private data, backups and shared tools refuse')
for name in ('Hermes', 'StorageBox', 'Storage Box', 'storage_box', 'backups',
             'restic', 'Documents', 'Desktop', 'Audio', 'ms-playwright', 'shared'):
    target = LAYOUT / name / 'old'
    target.mkdir(parents=True)
    result, rows = run('imac', snapshot('imac', [
        {'path': str(target), 'kind': 'task-artifact', 'evidence': {}}]))
    check(f'N excluded-path by name: {name}', result.returncode == 2 and rows
          and 'excluded-path' in rows[0]['reasons'], f'{name} -> {result.stdout.strip()}')
for ext in ('private.wav', 'notes.pdf', 'old.bak'):
    target = LAYOUT / 'ext-holder' / ext
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('protected')
    result, rows = run('imac', snapshot('imac', [
        {'path': str(target.parent), 'kind': 'task-artifact', 'evidence': {}}]))
    check(f'N descendant private extension refuses: {ext}', result.returncode == 2 and rows
          and 'excluded-descendant' in rows[0]['reasons'], f'{ext} -> {result.stdout.strip()}')
    target.unlink()

# ---------------------------------------------------------------------------
# Case O: large-tree scan completes promptly (per-descendant realpath removed)
# ---------------------------------------------------------------------------
log('== Case O: large candidate tree scan timing (HEAD vs pre-fix revision)')
import time
scale = LAYOUT / 'scale'
scale.mkdir()
for i in range(1200):
    d = scale / ('dir-%04d' % i)
    d.mkdir()
    for j in range(12):
        (d / ('file-%02d.txt' % j)).write_text('x')
scale_item = {'path': str(scale), 'kind': 'old-build',
              'owner_uid': scale.stat().st_uid,
              'release_root': str(scale.parent),
              'current_link': str(current_link),
              'rollback_link': str(rollback_link),
              'evidence': supplied_evidence(scale, uid=501)}
# scale is not a child of releases/, so keep it as a plain worktree-shaped probe
scale_item['kind'] = 'task-artifact'
scale_item['repository_root'] = str(repo)
candidate = json.loads(json.dumps(item))
candidate['path'] = str(scale)
candidate['owner_uid'] = scale.stat().st_uid
candidate['task_status_path'] = str(status_file)
candidate['task_meta_path'] = str(meta_file)
# The scale path is not under the repo, so only measure the path traversal by
# using an inventory object whose native evidence is complete for the shared
# probes; git association still refuses, but the walk dominates the timing.
candidate['evidence'] = supplied_evidence(scale, uid=501)
for key in ('git-status', 'git-pushed', 'git-landed', 'git-default-branch',
            'git-landing-sha', 'treehouse', 'task-status', 'task-meta'):
    candidate['evidence'][key] = case_b_evidence[key]
inv = TMP / 'scale-inventory.json'
inv.write_text(json.dumps(snapshot('imac', [candidate])))

def timed(script):
    start = time.monotonic()
    proc = subprocess.run(['python3', script, 'imac', '--inventory', str(inv)],
                          text=True, capture_output=True)
    elapsed = time.monotonic() - start
    rows = [json.loads(l) for l in proc.stdout.splitlines() if l.strip()]
    return elapsed, rows

head_time, head_rows = timed(str(WORKTREE / 'bin' / 'fm-disk-simulate.py'))
pre = subprocess.run(['git', '-C', str(WORKTREE), 'show',
                      '02db72ee:bin/fm-disk-simulate.py'], text=True, capture_output=True)
pre_script = LAYOUT / 'pre-fix-fm-disk-simulate.py'
pre_script.write_text(pre.stdout)
pre_time, pre_rows = timed(str(pre_script))
check('O1 both revisions reach the same decision (behavior preserved)',
      json.dumps(head_rows) == json.dumps(pre_rows),
      f'head={head_rows} pre={pre_rows}')
check('O2 large-tree scan not slower than pre-fix revision',
      head_time <= pre_time, 'head=%.3fs pre=%.3fs entries=~%d' % (head_time, pre_time, 1200 * 13))
log('    large-tree timing: head=%.3fs pre-fix=%.3fs' % (head_time, pre_time))

# ---------------------------------------------------------------------------
log('')
failed = [name for name, ok in RESULTS if not ok]
log('TOTAL %d  PASS %d  FAIL %d' % (len(RESULTS), len(RESULTS) - len(failed), len(failed)))
for name in failed:
    log('FAILED: ' + name)
shutil.rmtree(TMP, ignore_errors=True)
sys.exit(1 if failed else 0)
