#!/usr/bin/env bash
# Simulation reporting safety: machine authority, protected boundaries, native
# evidence, missing prerequisites and no mutation of isolated candidate layouts.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot disk-simulation)
export ROOT TMP_ROOT
python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ['ROOT'])
tmp = Path(os.environ['TMP_ROOT'])
layout = tmp / 'layout'
layout.mkdir()


def invoke(machine, value=None, flags=()):
    args = ['bash', str(root / 'bin' / ('fm-disk-simulate-' + machine + '.sh'))]
    if value is not None:
        inventory = tmp / 'inventory.json'
        inventory.write_text(json.dumps(value))
        args += ['--inventory', str(inventory)]
    result = subprocess.run(args + list(flags), text=True, capture_output=True)
    assert result.stdout, (result.returncode, result.stderr)
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    assert all(row['simulation_only'] is True for row in rows)
    return result.returncode, rows


def snapshot(machine, objects):
    return {'schema': 1, 'machine': machine, 'provenance': {
        'kind': 'fixture', 'source': 'isolated test layout',
        'observed_at': datetime.datetime.now(datetime.timezone.utc).isoformat()},
        'objects': objects}


def obj(path, kind):
    return {'path': str(path), 'kind': kind, 'evidence': {}}


# Removing FT's authority guard must fail even when a foreign inventory is supplied.
code, rows = invoke('ft', snapshot('imac', [obj(layout, 'worktree')]))
assert code == 2 and rows[0]['decision'] == 'refused'
assert rows[0]['whitelist'] is None and 'missing-whitelist' in rows[0]['reasons']
print('ok - FT refuses foreign authority and missing whitelist/inventory')

# Missing inputs must be an explicit JSON refusal, never an empty successful report.
for machine in ('imac', 'vps', 'staging'):
    code, rows = invoke(machine)
    assert code == 2 and 'missing-inventory' in rows[0]['reasons']
print('ok - all machine entry points refuse missing inventory')

# A report cannot transfer another machine's approved line.
code, rows = invoke('staging', snapshot('imac', [obj(layout, 'worktree')]))
assert code == 2 and 'machine-mismatch' in rows[0]['reasons']
code, rows = invoke('vps', snapshot('vps', [obj(layout, 'worktree')]))
assert code == 2 and rows[0]['whitelist'] is None
print('ok - machine-specific authority cannot be borrowed')

# These are representative user data and shared tool exclusions, not arbitrary defaults.
for name in ('Hermes', 'Desktop', 'Documents', 'Audio',
             'backups', 'StorageBox', 'Storage Box', 'storage_box',
             'restic', 'ms-playwright', 'ms_playwright'):
    path = layout / name / 'old'
    path.mkdir(parents=True)
    code, rows = invoke('imac', snapshot('imac', [obj(path, 'task-artifact')]))
    assert code == 2 and 'excluded-path' in rows[0]['reasons'], (name, rows)
    assert rows[0]['whitelist']['id'] == 'imac.task-artifact'
for name in ('data', 'state'):
    code, rows = invoke('imac', snapshot('imac', [obj(root / name / 'old', 'task-artifact')]))
    assert code == 2 and 'excluded-path' in rows[0]['reasons'], (name, rows)
print('ok - exclusions and the firstmate home data/state override valid whitelist rows')

# An innocuous parent cannot hide protected descendants or a symlink escape.
parent = layout / 'scratch'
(parent / 'backups').mkdir(parents=True)
(parent / 'backups' / 'important').write_text('keep')
code, rows = invoke('imac', snapshot('imac', [obj(parent, 'task-artifact')]))
assert code == 2 and 'excluded-descendant' in rows[0]['reasons']
for descendant in ('Storage Box', 'ms_playwright'):
    holder = layout / ('holder-' + descendant.replace(' ', '-'))
    (holder / descendant).mkdir(parents=True)
    code, rows = invoke('imac', snapshot('imac', [obj(holder, 'task-artifact')]))
    assert code == 2 and 'excluded-descendant' in rows[0]['reasons'], (descendant, rows)
regular = layout / 'regular-object'
regular.write_text('not a directory')
code, rows = invoke('imac', snapshot('imac', [obj(regular, 'task-artifact')]))
assert code == 2 and 'unsupported-object-type' in rows[0]['reasons'], rows
link = layout / 'apparently-safe'
link.symlink_to(layout / 'Documents', target_is_directory=True)
code, rows = invoke('imac', snapshot('imac', [obj(link, 'task-artifact')]))
assert code == 2 and 'symlink-boundary' in rows[0]['reasons']
print('ok - protected descendants and symlink escapes refuse')

# Unknown paths/use/ownership are not converted into candidates by boolean claims.
safe = layout / 'scratch-only'
safe.mkdir()
(safe / 'output').write_text('unchanged')
item = obj(safe, 'task-artifact')
item.update(clean=True, landed=True, unused=True, owner='fred')
code, rows = invoke('imac', snapshot('imac', [item]))
assert code == 2 and rows[0]['decision'] == 'refused'
assert 'missing-native-evidence' in rows[0]['reasons']
print('ok - asserted eligibility booleans do not substitute for native evidence')

# Every recognized machine line is reported even when evidence is incomplete.
for machine, kinds in [('imac', ['worktree', 'task-artifact', 'homebrew-version', 'simulator']),
                       ('vps', ['journal', 'temporary-file', 'docker-image']),
                       ('staging', ['old-build'])]:
    code, rows = invoke(machine, snapshot(machine, [obj(safe, kind) for kind in kinds]))
    assert code == 2 and len(rows) == len(kinds)
    assert [row['whitelist']['id'] for row in rows] == [machine + '.' + kind for kind in kinds]
    assert all(row['whitelist']['report_line'] in range(53, 61) for row in rows)
    assert all(row['provenance']['kind'] == 'fixture' for row in rows)
print('ok - every approved row retains exact policy mapping and fixture provenance')

# Bad timestamps and empty inventories must not produce an apparent all-clear.
bad = snapshot('staging', [obj(safe, 'old-build')])
bad['provenance']['observed_at'] = '2000-01-01T00:00:00+00:00'
code, rows = invoke('staging', bad)
assert code == 2 and 'stale-inventory' in rows[0]['reasons']
code, rows = invoke('imac', snapshot('imac', []))
assert code == 2 and 'empty-inventory' in rows[0]['reasons']
for flag in ('--apply', '--delete', '--prune', '--archive'):
    code, rows = invoke('imac', flags=(flag,))
    assert code == 2 and 'unsupported-arguments' in rows[0]['reasons']
print('ok - stale/empty inputs and destructive options refuse')

# Test the real Git observation, including clean, dirty, unpushed and unlanded states.
repo = layout / 'repo'
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
subprocess.run(['git', '-C', str(repo), 'config', 'user.email', 'fixture@example.test'], check=True)
subprocess.run(['git', '-C', str(repo), 'config', 'user.name', 'Fixture'], check=True)
(repo / 'file').write_text('base')
subprocess.run(['git', '-C', str(repo), 'add', 'file'], check=True)
subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'base'], check=True)
item = obj(repo, 'worktree')
item['landed_ref'] = 'HEAD'
def git_record(args):
    command = ['git', '-C', str(repo)] + args
    result = subprocess.run(command, text=True, capture_output=True)
    return {'argv': command, 'exit': result.returncode,
            'stdout': result.stdout, 'stderr': result.stderr}

item['evidence']['git-status'] = git_record(['status', '--porcelain=v1', '--untracked-files=all'])
item['evidence']['git-pushed'] = git_record(['rev-list', '--count', '@{upstream}..HEAD'])
code, rows = invoke('imac', snapshot('imac', [item]))
assert 'unknown-push-state' in rows[0]['reasons']
(repo / 'file').write_text('dirty')
item['evidence']['git-status'] = git_record(['status', '--porcelain=v1', '--untracked-files=all'])
code, rows = invoke('imac', snapshot('imac', [item]))
assert 'dirty-worktree' in rows[0]['reasons']
print('ok - real Git dirtiness and absent push proof refuse')

# Positive fixtures MODEL native observations; only layout/Git observations above
# are live local proof. These records must never be presented as live inventory.
def record(argv, stdout='', exit=0, stderr=''):
    return {'argv': argv, 'stdout': stdout, 'exit': exit, 'stderr': stderr}


def idle_item(path, kind):
    entry = obj(path, kind)
    entry['owner_uid'] = path.stat().st_uid
    entry['evidence'] = {
        'identity': record(['id', '-u'], '0\n'),
        'processes': record(['ps', '-axo', 'pid=,uid=,comm='], '1 0 /sbin/init\n'),
        'open-files': record(['lsof', '-nP', '+D', str(path)], exit=1)}
    return entry


# Removing audio-file and reservation protection must turn these into candidates.
releases = layout / 'releases'
for name in ('old', 'current', 'rollback'):
    (releases / name).mkdir(parents=True)
current = layout / 'current'
rollback = layout / 'last-rollback'
current.symlink_to(releases / 'current', target_is_directory=True)
rollback.symlink_to(releases / 'rollback', target_is_directory=True)
build = idle_item(releases / 'old', 'old-build')
build.update(release_root=str(releases), current_link=str(current),
             rollback_link=str(rollback))
code, rows = invoke('staging', snapshot('staging', [build]))
assert code == 0 and rows[0]['decision'] == 'candidate', rows
for filename, reason in [('private.wav', 'excluded-descendant'),
                         ('.lease', 'leased-reserved-or-active-marker')]:
    marker = releases / 'old' / filename
    marker.write_text('protected')
    code, rows = invoke('staging', snapshot('staging', [build]))
    assert code == 2 and reason in rows[0]['reasons'], rows
    marker.unlink()
for name in ('current', 'rollback'):
    protected_build = idle_item(releases / name, 'old-build')
    protected_build.update(release_root=str(releases), current_link=str(current),
                           rollback_link=str(rollback))
    code, rows = invoke('staging', snapshot('staging', [protected_build]))
    assert code == 2 and 'current-or-last-rollback' in rows[0]['reasons'], rows
print('ok - staging candidates protect current/rollback, private audio and reservations')

# Absence of file handles alone cannot establish no active shared worker/tool.
build['evidence']['processes']['stdout'] += '123 501 /usr/bin/clang\n'
code, rows = invoke('staging', snapshot('staging', [build]))
assert code == 2 and 'active-shared-worker-or-tool' in rows[0]['reasons']
build['evidence']['processes']['stdout'] = '1 0 /sbin/init\n'
build['evidence']['open-files']['stderr'] = 'permission denied'
code, rows = invoke('staging', snapshot('staging', [build]))
assert code == 2 and 'incomplete-native-evidence' in rows[0]['reasons']
print('ok - active workers and incomplete native inventory refuse')

# Docker must consider stopped containers, not just running container references.
image_id = 'sha256:' + 'a' * 64
container_id = 'b' * 64
image = {'path': image_id, 'kind': 'docker-image', 'evidence': {
    'identity': record(['id', '-u'], '0\n'),
    'processes': record(['ps', '-axo', 'pid=,uid=,comm='], '1 0 /sbin/init\n'),
    'image-owner': record(['stat', '-c', '%u', '/var/run/docker.sock'], '0\n'),
    'image': record(['docker', 'image', 'inspect', image_id], json.dumps([{'Id': image_id}])),
    'containers': record(['docker', 'container', 'ls', '-aq', '--no-trunc'], '')}}
code, rows = invoke('vps', snapshot('vps', [image]))
assert code == 0 and rows[0]['whitelist']['report_line'] == 59, rows
image['evidence']['containers']['stdout'] = container_id + '\n'
image['evidence']['container-inspect'] = record(
    ['docker', 'container', 'inspect', container_id],
    json.dumps([{'Id': container_id, 'Image': image_id, 'State': {'Running': False}}]))
code, rows = invoke('vps', snapshot('vps', [image]))
assert code == 2 and 'image-referenced-by-container' in rows[0]['reasons'], rows
print('ok - Docker stopped-container references refuse')

# Malformed native JSON must produce a refusal, not crash or silently skip input.
image['evidence']['image']['stdout'] = '[null]'
code, rows = invoke('vps', snapshot('vps', [image]))
assert code == 2 and 'invalid-native-evidence' in rows[0]['reasons'], rows
print('ok - malformed native observations refuse without losing the object')

# A named keg must really be inside the native package cellar and replaced.
keg = layout / 'Cellar' / 'example' / '1.0'
keg.mkdir(parents=True)
brew_item = idle_item(keg, 'homebrew-version')
brew_item['package'] = 'example'
formula = {'name': 'example', 'installed': [{'version': '1.0'}, {'version': '2.0'}],
           'linked_keg': '2.0', 'pinned': False, 'keg_only': False}
brew_item['evidence']['brew'] = record(['brew', 'info', '--json=v2', 'example'],
                                      json.dumps({'formulae': [formula]}))
# Without native cellar binding an arbitrary directory named Cellar is not proof.
code, rows = invoke('imac', snapshot('imac', [brew_item]))
assert code == 2 and 'missing-native-evidence' in rows[0]['reasons'], rows
brew_item['evidence']['cellar'] = record(['brew', '--cellar', 'example'], str(keg.parent) + '\n')
code, rows = invoke('imac', snapshot('imac', [brew_item]))
assert code == 0, rows
formula['linked_keg'] = '1.0'
brew_item['evidence']['brew']['stdout'] = json.dumps({'formulae': [formula]})
code, rows = invoke('imac', snapshot('imac', [brew_item]))
assert code == 2 and 'not-replaced-or-protected-keg' in rows[0]['reasons'], rows
print('ok - Homebrew requires native cellar binding and excludes the linked keg')

# Unavailable is necessary but not sufficient: a booted/available device refuses.
udid = '12345678-1234-1234-1234-123456789ABC'
device = layout / 'Library' / 'Developer' / 'CoreSimulator' / 'Devices' / udid
(device / 'data').mkdir(parents=True)
(device / 'device.plist').write_text('device')
sim = idle_item(device, 'simulator')
sim['udid'] = udid
devices = {'devices': {'runtime': [{'udid': udid, 'isAvailable': False, 'state': 'Shutdown'}]}}
sim['evidence']['simulators'] = record(['xcrun', 'simctl', 'list', 'devices', '--json'],
                                      json.dumps(devices))
code, rows = invoke('imac', snapshot('imac', [sim]))
assert code == 0, rows
devices['devices']['runtime'][0]['state'] = 'Booted'
sim['evidence']['simulators']['stdout'] = json.dumps(devices)
code, rows = invoke('imac', snapshot('imac', [sim]))
assert code == 2 and 'available-active-or-unknown-simulator' in rows[0]['reasons'], rows
sim['evidence']['simulators']['stdout'] = '{"devices":[]}'
code, rows = invoke('imac', snapshot('imac', [sim]))
assert code == 2 and 'invalid-native-evidence' in rows[0]['reasons'], rows
print('ok - simulator availability/state and malformed device inventory refuse')

# A local ancestor claim alone is not proof of landing on the default branch.
(repo / 'file').write_text('base')
branch = subprocess.check_output(['git', '-C', str(repo), 'branch', '--show-current'], text=True).strip()
remote = layout / 'origin.git'
subprocess.run(['git', 'clone', '--bare', '-q', str(repo), str(remote)], check=True)
subprocess.run(['git', '-C', str(repo), 'remote', 'add', 'origin', str(remote)], check=True)
subprocess.run(['git', '-C', str(repo), 'fetch', '-q', 'origin'], check=True)
subprocess.run(['git', '-C', str(repo), 'branch', '--set-upstream-to=origin/' + branch], check=True,
               capture_output=True)
subprocess.run(['git', '-C', str(repo), 'symbolic-ref', 'refs/remotes/origin/HEAD',
                'refs/remotes/origin/' + branch], check=True)
sha = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
copy = idle_item(repo, 'worktree')
copy.update(repository_root=str(repo), pool_root=str(layout), landed_ref=sha)
copy['evidence'].update({
    'git-status': git_record(['status', '--porcelain=v1', '--untracked-files=all']),
    'git-pushed': git_record(['rev-list', '--count', '@{upstream}..HEAD']),
    'git-landed': git_record(['merge-base', '--is-ancestor', 'HEAD', sha]),
    'treehouse': record(['treehouse', 'status', '--json', '--root', str(layout)], json.dumps([{
        'name': 'fixture', 'path': str(repo), 'status': 'available', 'branch': branch,
        'lease_id': '', 'lease_holder': '', 'leased_at': None, 'processes': []}]))})
code, rows = invoke('imac', snapshot('imac', [copy]))
assert code == 2 and 'unknown-default-branch-landing' in rows[0]['reasons'], rows
copy['landing_branch'] = 'refs/remotes/origin/' + branch
copy['evidence']['git-default-branch'] = git_record(['symbolic-ref', 'refs/remotes/origin/HEAD'])
copy['evidence']['git-landing-sha'] = git_record(['rev-parse', '--verify',
                                               copy['landing_branch'] + '^{commit}'])
code, rows = invoke('imac', snapshot('imac', [copy]))
assert code == 0, rows
pool = json.loads(copy['evidence']['treehouse']['stdout'])
pool[0]['lease_id'] = 'reserved-by-another-task'
copy['evidence']['treehouse']['stdout'] = json.dumps(pool)
code, rows = invoke('imac', snapshot('imac', [copy]))
assert code == 2 and 'leased-reserved-active-or-unverified-copy' in rows[0]['reasons'], rows
print('ok - landing must bind to native default-branch SHA and leased copies refuse')

# End-of-task artifacts use the existing native metadata/status association;
# normal done events do not invent a new requirement to carry a commit SHA.
pool[0]['lease_id'] = ''
artifact_path = repo / 'build-output'
artifact_path.mkdir()
artifact = idle_item(artifact_path, 'task-artifact')
artifact.update(repository_root=str(repo), pool_root=str(layout), landed_ref=sha,
                landing_branch=copy['landing_branch'],
                task_status_path=str(tmp / 'fixture.status'),
                task_meta_path=str(tmp / 'fixture.meta'))
for key in ('git-status', 'git-pushed', 'git-landed', 'git-default-branch', 'git-landing-sha'):
    artifact['evidence'][key] = copy['evidence'][key]
artifact['evidence']['treehouse'] = record(
    ['treehouse', 'status', '--json', '--root', str(layout)], json.dumps(pool))
artifact['evidence']['task-status'] = record(
    ['cat', artifact['task_status_path']], 'done: local validation complete\n')
artifact['evidence']['task-meta'] = record(
    ['cat', artifact['task_meta_path']], 'worktree=' + str(repo) + '\nkind=ship\n')
code, rows = invoke('imac', snapshot('imac', [artifact]))
assert code == 0, rows
artifact['evidence']['task-meta']['stdout'] = 'worktree=/another/copy\nkind=ship\n'
code, rows = invoke('imac', snapshot('imac', [artifact]))
assert code == 2 and 'unknown-artifact-association' in rows[0]['reasons'], rows
print('ok - task artifacts require native completed-task metadata association')

# Imported argv is data, never permission to run even a seemingly harmless tool.
sentinel = tmp / 'must-not-be-created'
build['evidence']['identity'] = record(['touch', str(sentinel)], '0\n')
code, rows = invoke('staging', snapshot('staging', [build]))
assert code == 2 and not sentinel.exists(), rows
print('ok - imported commands never execute')

# A malformed object must not crash and hide later explicit candidate refusals.
code, rows = invoke('imac', snapshot('imac', [obj('/invalid/\x00', 'task-artifact'),
                                            obj(safe, 'task-artifact')]))
assert code == 2 and len(rows) == 2 and all(r['decision'] == 'refused' for r in rows), rows
invalid_schema = snapshot('imac', [obj(safe, 'task-artifact')])
invalid_schema['schema'] = True
code, rows = invoke('imac', invalid_schema)
assert code == 2 and rows[0]['path'] is None and 'invalid-inventory' in rows[0]['reasons'], rows
print('ok - invalid paths and ambiguous schema types refuse without losing objects')

# A report is not an action: actual contents survive all invocations.
assert (safe / 'output').read_text() == 'unchanged'
assert (parent / 'backups' / 'important').read_text() == 'keep'
print('ok - concrete candidate and protected contents remain unchanged')
PY
