#!/usr/bin/env python3
"""Simulation-only evaluator for explicitly named local objects and native snapshots.

Usage: fm-disk-simulate-MACHINE.sh --inventory FILE
Exit 0: every submitted object is a simulation candidate; 2: one or more refusals.
No command in a snapshot is executed. No cleanup command or apply mode exists.
Python 3.9+ standard library only. See --help for the inventory contract.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

POLICY = {
    'imac': {
        'worktree': (53, 'copies isolees fusionnees, propres, inactives'),
        'task-artifact': (54, 'fin de tache'),
        'homebrew-version': (55, 'anciennes versions Homebrew deja remplacees (pas ms-playwright, pas le cache npm actif)'),
        'simulator': (56, 'simulateurs marques indisponibles'),
    },
    'vps': {
        'journal': (57, 'journaux'),
        'temporary-file': (58, 'tmp'),
        'docker-image': (59, 'images Docker inutilisees'),
    },
    'staging': {'old-build': (60, 'anciens builds hors release courante et dernier rollback')},
    'ft': {},
}
EXCLUDED = frozenset(('data', 'state', 'hermes', 'desktop', 'documents', 'document',
                      'audio', 'music', 'musique', 'spectrasonics', 'backups', 'backup',
                      'storagebox', 'storage-box', 'restic', 'ms-playwright', 'shared'))
BUSY = re.compile(r'(?:^|[/\s-])(?:claude|codex|pi|opencode|herdr|hermes|cursor|'
                  r'chrome|chromium|playwright|xcode|simulator|simctl|npm|pnpm|yarn|'
                  r'brew|clang|gcc|make|cmake|ninja|xcodebuild|swift)(?:$|[/\s.-])', re.I)
HELP = """SIMULATION ONLY. No apply, deletion, archive, remote connection or service action.
Four entry points: imac, vps, staging, ft. FT has no whitelist or inventory authority.

Input JSON (schema 1):
  machine: exact entry point name
  provenance: {kind: "fixture"|"local", source: nonempty description,
               observed_at: timezone-qualified ISO8601 observation time}
  objects: [{path: absolute explicitly named local path, kind: approved kind,
             owner_uid: numeric expected owner, evidence: {...}}]
Snapshots must be current (at most five minutes old, no future timestamps).
This bounds evidence age, not disk usage: no disk threshold/growth subsystem exists.
Local filesystem metadata and descendants of ONLY the named object are read.
The inventory must be collected on this machine; paths are never mapped to another
machine. Each evidence record is {argv: [strings], exit: integer,
stdout: string, stderr: string}. Imported argv is NEVER executed. Successful raw
observations must have empty stderr. Missing/partial/foreign observations refuse.
A snapshot is operator-supplied evidence, not authentication or permission to clean.

Common evidence keys (literal argv contracts):
  identity: ["id", "-u"] (must report 0 for complete privileged usage inventory)
  processes: ["ps", "-axo", "pid=,uid=,comm="] (complete, nonempty; active workers,
    tools, browsers, builds or simulators refuse, even outside the named directory)
  open-files: ["lsof", "-nP", "+D", PATH] (exit 1, empty stdout AND stderr = no use)
All paths require owner_uid matching lstat, no symlink boundary/descendant, no
protected ancestor or descendant, no mount boundary, and a named non-root path.

Kinds and additional evidence:
  imac worktree / task-artifact: repository_root must equal path for worktree,
    contain path for artifact. landed_ref is an immutable 40/64-hex commit ID.
    git-status: ["git","-C",ROOT,"status","--porcelain=v1","--untracked-files=all"]
    git-pushed: ["git","-C",ROOT,"rev-list","--count","@{upstream}..HEAD"] -> 0
    git-landed: ["git","-C",ROOT,"merge-base","--is-ancestor","HEAD",LANDED_SHA]
    landing_branch is the native local refs/remotes/origin default-branch ref.
    git-default-branch: ["git","-C",ROOT,"symbolic-ref","refs/remotes/origin/HEAD"]
    git-landing-sha: ["git","-C",ROOT,"rev-parse","--verify",BRANCH+"^{commit}"]
      Default-branch identity and SHA must match landing_branch and landed_ref.
      No fetch occurs; snapshots cannot prove newer remote changes or authorize action.
    treehouse: ["treehouse","status","--json","--root",POOL_ROOT]
      POOL_ROOT supplied on object; native Treehouse v3.1 JSON entry must uniquely
      match ROOT, have status available, empty lease_id/lease_holder, null leased_at,
      empty processes, no branch_error/recovery fields. Missing fields refuse.
    task-artifact additionally task-status: ["cat",TASK_STATUS_PATH] (latest event
      done), task-meta: ["cat",TASK_META_PATH] (one worktree=ROOT, kind=ship).
      Paths supplied on object must share the same task basename and directory.
      Native default-branch landing proof is required separately.
  imac homebrew-version: path must be CELLAR/PACKAGE/VERSION, package supplied.
    brew: ["brew","info","--json=v2",PACKAGE]; named installed keg must differ
      from linked_keg, linked_keg must itself be installed; package must not be
      pinned or keg_only. No blanket package/build cache cleanup.
    cellar: ["brew","--cellar",PACKAGE] must match the package parent directory.
  imac simulator: udid supplied; path basename must equal UDID under Devices.
    simulators: ["xcrun","simctl","list","devices","--json"]; unique matching
      UDID isAvailable=false, state=Shutdown. No unavailable-device deletion.
  staging old-build: release_root, current_link and rollback_link supplied; path
    is a direct child of release_root; both links must be actual local symlinks
    to two distinct existing releases. Neither target is eligible. Fred owns
    execution/handoff; this program never contacts or deploys to staging.
  vps journal / temporary-file: reports the concrete object and common evidence,
    but refuses native-retention-eligibility-unproven. Active timers do not prove
    any particular journal/tmp object may be removed. No native destructive or
    nominal cleanup tool is invoked to manufacture that missing proof.
  vps docker-image: path is an immutable sha256:64hex identifier (not a file).
    image: ["docker","image","inspect",ID]; exactly one matching native image.
    containers: ["docker","container","ls","-aq","--no-trunc"] and, if nonempty,
    container-inspect: ["docker","container","inspect",ID1,...] in listed order;
    every stopped or running container is checked, not only running containers.
    image-owner: ["stat","-c","%u","/var/run/docker.sock"] -> 0, identity -> 0.
    Missing/partial ownership/container inventory refuses. No daemon is contacted
    by this evaluator: these are previously captured native read-only outputs.

Every JSONL row retains machine, original path, exact approved section 3 line,
provenance, evidence digest/facts and candidate/refusal reasons. Candidate means
only eligible according to this observation; it never authorizes actual cleanup.
Fixture observations are always labeled fixture and cannot prove live eligibility.
StorageBox/archives, private data, Firstmate data/state, backups, active/shared tools
and work not clean/pushed/landed are excluded regardless of the submitted kind.
"""


class Refusal(Exception):
    pass


def protected_name(name):
    normalized = name.casefold().lstrip('.')
    return (normalized in EXCLUDED
            or any(token in EXCLUDED for token in re.split(r'[-_ ]', normalized))
            or Path(normalized).suffix in ('.wav', '.mp3', '.aif', '.aiff', '.flac',
                                           '.m4a', '.ogg', '.pdf', '.doc', '.docx',
                                           '.bak', '.backup', '.dump'))


def protected(path):
    return any(protected_name(part) for part in Path(path).parts)


def emit(machine, path, kind, provenance, reasons, facts=None):
    approved = POLICY[machine].get(kind)
    whitelist = None if approved is None else {
        'id': machine + '.' + kind, 'section': 3, 'report_line': approved[0],
        'line': approved[1]}
    print(json.dumps({'simulation_only': True, 'machine': machine, 'path': path,
                      'whitelist': whitelist, 'provenance': provenance,
                      'decision': 'refused' if reasons else 'candidate',
                      'reasons': list(dict.fromkeys(reasons)), 'evidence': facts or []},
                     ensure_ascii=False, sort_keys=True))


def native(item, key, argv, facts, codes=(0,)):
    record = item.get('evidence', {}).get(key)
    if not isinstance(record, dict):
        raise Refusal('missing-native-evidence')
    if (record.get('argv') != argv or type(record.get('exit')) is not int
            or not isinstance(record.get('stdout'), str)
            or not isinstance(record.get('stderr'), str)):
        raise Refusal('invalid-native-evidence')
    facts.append({'observation': key, 'argv': argv, 'exit': record['exit'],
                  'sha256': hashlib.sha256(record['stdout'].encode()).hexdigest(),
                  'stdout': record['stdout'], 'stderr': record['stderr']})
    if record['exit'] not in codes or record['stderr']:
        raise Refusal('incomplete-native-evidence')
    return record['stdout']


def inspect_path(item, reasons, facts):
    text = item['path']
    path = Path(text)
    if ('\x00' in text or not path.is_absolute() or '..' in path.parts
            or path == Path(path.anchor)):
        reasons.append('unknown-path-boundary')
        return None
    if protected(path):
        reasons.append('excluded-path')
        return None
    try:
        for entry in (path,) + tuple(path.parents):
            if entry.is_symlink():
                reasons.append('symlink-boundary')
                return None
        st = path.lstat()
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            reasons.append('unsupported-object-type')
            return None
        facts.append({'observation': 'local-lstat', 'uid': st.st_uid,
                      'device': st.st_dev, 'inode': st.st_ino, 'size': st.st_size})
        if type(item.get('owner_uid')) is not int or item['owner_uid'] != st.st_uid:
            reasons.append('unknown-ownership')
        # Traverse only the explicitly named object, never follow symlinks or mounts.
        if path.is_dir():
            pending = [path]
            while pending:
                directory = pending.pop()
                with os.scandir(directory) as entries:
                    for entry in entries:
                        if protected_name(entry.name):
                            reasons.append('excluded-descendant')
                            return None
                        if (entry.name in ('.lease', '.reserved', '.active')
                                or entry.name.endswith('.lock')):
                            reasons.append('leased-reserved-or-active-marker')
                            return None
                        if entry.is_symlink():
                            reasons.append('symlink-descendant')
                            return None
                        metadata = entry.stat(follow_symlinks=False)
                        if metadata.st_dev != st.st_dev:
                            reasons.append('mount-boundary')
                            return None
                        if metadata.st_uid != st.st_uid:
                            reasons.append('mixed-ownership')
                            return None
                        if entry.is_dir(follow_symlinks=False):
                            pending.append(Path(entry.path))
    except OSError as error:
        reasons.append('unreadable-or-missing-path')
        facts.append({'observation': 'path-error', 'error': str(error)})
        return None
    return path


def unused(item, path, facts, reasons):
    try:
        if native(item, 'identity', ['id', '-u'], facts).strip() != '0':
            reasons.append('incomplete-usage-privileges')
        processes = native(item, 'processes', ['ps', '-axo', 'pid=,uid=,comm='], facts)
        rows = processes.splitlines()
        if not rows or any(not re.fullmatch(r'\s*\d+\s+\d+\s+\S.*', row) for row in rows):
            reasons.append('unknown-process-inventory')
        elif any(BUSY.search(row.split(None, 2)[2]) for row in rows):
            reasons.append('active-shared-worker-or-tool')
        if path is not None:
            output = native(item, 'open-files', ['lsof', '-nP', '+D', str(path)], facts, (0, 1))
            record = item['evidence']['open-files']
            if output or record['exit'] != 1:
                reasons.append('object-in-use-or-unknown')
    except Refusal as error:
        reasons.append(str(error))


def git_eligibility(item, path, facts, reasons):
    root = item.get('repository_root', str(path))
    prefix = ['git', '-C', root]
    try:
        if native(item, 'git-status', prefix + ['status', '--porcelain=v1', '--untracked-files=all'], facts):
            reasons.append('dirty-worktree')
    except Refusal as error:
        reasons.append(str(error))
    try:
        if native(item, 'git-pushed', prefix + ['rev-list', '--count', '@{upstream}..HEAD'], facts).strip() != '0':
            reasons.append('unpushed-work')
    except Refusal:
        reasons.append('unknown-push-state')
    landed = item.get('landed_ref', '')
    if not isinstance(landed, str) or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', landed):
        reasons.append('unknown-landing')
    else:
        try:
            native(item, 'git-landed', prefix + ['merge-base', '--is-ancestor', 'HEAD', landed], facts)
        except Refusal:
            reasons.append('unlanded-or-unknown-work')
    try:
        branch = item.get('landing_branch')
        if not isinstance(branch, str) or not re.fullmatch(r'refs/remotes/origin/[A-Za-z0-9_./-]+', branch):
            raise Refusal('unknown-default-branch-landing')
        default = native(item, 'git-default-branch',
                         prefix + ['symbolic-ref', 'refs/remotes/origin/HEAD'], facts).strip()
        observed = native(item, 'git-landing-sha',
                          prefix + ['rev-parse', '--verify', branch + '^{commit}'], facts).strip()
        if default != branch or observed != landed:
            raise Refusal('unknown-default-branch-landing')
    except Refusal:
        reasons.append('unknown-default-branch-landing')
    try:
        root_path = Path(root)
        if not root_path.is_absolute() or root_path.is_symlink() or not root_path.is_dir():
            raise Refusal('unknown-repository-boundary')
        if item['kind'] == 'worktree' and root_path != path:
            raise Refusal('unknown-repository-boundary')
        if item['kind'] == 'task-artifact' and (root_path == path or root_path not in path.parents):
            raise Refusal('unknown-artifact-association')
        pool = item.get('pool_root')
        if not isinstance(pool, str) or not Path(pool).is_absolute():
            raise Refusal('unknown-lease-inventory')
        data = json.loads(native(item, 'treehouse', ['treehouse', 'status', '--json', '--root', pool], facts))
        if not isinstance(data, list):
            raise Refusal('unknown-lease-inventory')
        matches = [entry for entry in data if isinstance(entry, dict) and entry.get('path') == root]
        if len(matches) != 1:
            raise Refusal('unknown-lease-inventory')
        entry = matches[0]
        required = ('status', 'lease_id', 'lease_holder', 'leased_at', 'processes', 'branch')
        if any(key not in entry for key in required):
            raise Refusal('unknown-lease-inventory')
        if (entry['status'] != 'available' or entry['lease_id'] != ''
                or entry['lease_holder'] != '' or entry['leased_at'] is not None
                or entry['processes'] != [] or not entry['branch']
                or any(entry.get(k) for k in ('branch_error', 'recovery_reason', 'recovery_backup'))):
            raise Refusal('leased-reserved-active-or-unverified-copy')
        if item['kind'] == 'task-artifact':
            status_path = item.get('task_status_path')
            if not isinstance(status_path, str) or not Path(status_path).is_absolute():
                raise Refusal('unknown-task-completion')
            text = native(item, 'task-status', ['cat', status_path], facts).splitlines()
            if not text or not text[-1].startswith('done:'):
                raise Refusal('unknown-task-completion')
            meta_path = item.get('task_meta_path')
            if (not isinstance(meta_path, str)
                    or Path(status_path).suffix != '.status'
                    or Path(status_path).with_suffix('.meta') != Path(meta_path)):
                raise Refusal('unknown-artifact-association')
            meta = native(item, 'task-meta', ['cat', meta_path], facts).splitlines()
            roots = [line[len('worktree='):] for line in meta if line.startswith('worktree=')]
            kinds = [line[len('kind='):] for line in meta if line.startswith('kind=')]
            if roots != [root] or kinds != ['ship']:
                raise Refusal('unknown-artifact-association')
    except (Refusal, ValueError, TypeError) as error:
        reasons.append(str(error) if isinstance(error, Refusal) else 'invalid-native-evidence')


def category(item, path, facts, reasons):
    kind = item['kind']
    if kind in ('worktree', 'task-artifact'):
        git_eligibility(item, path, facts, reasons)
    elif kind == 'old-build':
        try:
            root = Path(item['release_root'])
            if not root.is_absolute() or path.parent != root or root.is_symlink():
                raise Refusal('unknown-release-boundary')
            targets = []
            for key in ('current_link', 'rollback_link'):
                link = Path(item[key])
                if not link.is_absolute() or not link.is_symlink():
                    raise Refusal('unknown-current-or-rollback')
                target = link.resolve(strict=True)
                if target.parent != root or not target.is_dir():
                    raise Refusal('unknown-current-or-rollback')
                targets.append(target)
                facts.append({'observation': key, 'link': str(link), 'target': str(target)})
            if targets[0] == targets[1]:
                raise Refusal('unknown-current-or-rollback')
            if path in targets:
                raise Refusal('current-or-last-rollback')
            if not path.is_dir():
                raise Refusal('not-release-directory')
        except (KeyError, TypeError, OSError, RuntimeError, Refusal) as error:
            reasons.append(str(error) if isinstance(error, Refusal) else 'unknown-current-or-rollback')
    elif kind == 'homebrew-version':
        try:
            package = item.get('package')
            if not isinstance(package, str) or not re.fullmatch(r'[A-Za-z0-9@+_.-]+', package):
                raise Refusal('unknown-named-package')
            if path.parent.name != package or path.parent.parent.name != 'Cellar':
                raise Refusal('unknown-cellar-boundary')
            cellar = native(item, 'cellar', ['brew', '--cellar', package], facts).strip()
            if cellar != str(path.parent):
                raise Refusal('unknown-cellar-boundary')
            data = json.loads(native(item, 'brew', ['brew', 'info', '--json=v2', package], facts))
            formulae = data['formulae']
            if len(formulae) != 1 or formulae[0]['name'] != package:
                raise Refusal('unknown-named-package')
            formula = formulae[0]
            installed = [entry['version'] for entry in formula['installed']]
            linked = formula['linked_keg']
            if (path.name not in installed or linked not in installed or path.name == linked
                    or formula['pinned'] is not False or formula['keg_only'] is not False):
                raise Refusal('not-replaced-or-protected-keg')
        except (KeyError, TypeError, ValueError, Refusal) as error:
            reasons.append(str(error) if isinstance(error, Refusal) else 'invalid-native-evidence')
    elif kind == 'simulator':
        try:
            udid = item.get('udid')
            if not isinstance(udid, str) or not re.fullmatch(r'[0-9A-Fa-f-]{36}', udid):
                raise Refusal('unknown-simulator-identity')
            if path.name != udid or path.parent.name != 'Devices':
                raise Refusal('unknown-simulator-boundary')
            data = json.loads(native(item, 'simulators', ['xcrun', 'simctl', 'list', 'devices', '--json'], facts))
            if (not isinstance(data, dict) or not isinstance(data.get('devices'), dict)
                    or any(not isinstance(entries, list) for entries in data['devices'].values())
                    or any(not isinstance(entry, dict) for entries in data['devices'].values()
                           for entry in entries)):
                raise Refusal('invalid-native-evidence')
            matches = [entry for entries in data['devices'].values() for entry in entries
                       if entry.get('udid') == udid]
            if (len(matches) != 1 or matches[0].get('isAvailable') is not False
                    or matches[0].get('state') != 'Shutdown'):
                raise Refusal('available-active-or-unknown-simulator')
        except (KeyError, TypeError, ValueError, Refusal) as error:
            reasons.append(str(error) if isinstance(error, Refusal) else 'invalid-native-evidence')
    elif kind in ('journal', 'temporary-file'):
        reasons.append('native-retention-eligibility-unproven')


def docker(item, facts, reasons):
    identity = item['path']
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', identity):
        reasons.append('unknown-image-identity')
        return
    try:
        if native(item, 'image-owner', ['stat', '-c', '%u', '/var/run/docker.sock'], facts).strip() != '0':
            raise Refusal('unknown-image-ownership')
        images = json.loads(native(item, 'image', ['docker', 'image', 'inspect', identity], facts))
        if not isinstance(images, list) or len(images) != 1 or not isinstance(images[0], dict):
            raise Refusal('invalid-native-evidence')
        if images[0].get('Id') != identity:
            raise Refusal('unknown-image-identity')
        ids = native(item, 'containers', ['docker', 'container', 'ls', '-aq', '--no-trunc'], facts).splitlines()
        if any(not re.fullmatch(r'[0-9a-f]{64}', entry) for entry in ids) or len(ids) != len(set(ids)):
            raise Refusal('unknown-container-inventory')
        if ids:
            containers = json.loads(native(item, 'container-inspect', ['docker', 'container', 'inspect'] + ids, facts))
            if (not isinstance(containers, list) or len(containers) != len(ids)
                    or any(not isinstance(entry, dict) for entry in containers)
                    or {entry['Id'] for entry in containers} != set(ids)
                    or any(not isinstance(entry.get('Image'), str) for entry in containers)):
                raise Refusal('unknown-container-inventory')
            if any(entry['Image'] == identity for entry in containers):
                raise Refusal('image-referenced-by-container')
    except (Refusal, KeyError, TypeError, ValueError) as error:
        reasons.append(str(error) if isinstance(error, Refusal) else 'invalid-native-evidence')


def main():
    machine = sys.argv[1] if len(sys.argv) > 1 else ''
    if machine not in POLICY:
        return 2
    args = sys.argv[2:]
    if args in (['--help'], ['-h']):
        print(HELP)
        return 0
    if machine == 'ft':
        emit(machine, None, None, None, ['missing-whitelist', 'missing-inventory'])
        return 2
    if not args:
        emit(machine, None, None, None, ['missing-inventory'])
        return 2
    if len(args) != 2 or args[0] != '--inventory':
        emit(machine, None, None, None, ['unsupported-arguments'])
        return 2
    try:
        inventory = json.loads(Path(args[1]).read_text())
        if (not isinstance(inventory, dict) or type(inventory.get('schema')) is not int
                or inventory['schema'] != 1):
            raise Refusal('invalid-inventory')
        if inventory.get('machine') != machine:
            raise Refusal('machine-mismatch')
        provenance = inventory.get('provenance')
        if (not isinstance(provenance, dict) or provenance.get('kind') not in ('fixture', 'local')
                or not isinstance(provenance.get('source'), str) or not provenance['source'].strip()):
            raise Refusal('missing-provenance')
        timestamp = dt.datetime.fromisoformat(provenance['observed_at'].replace('Z', '+00:00'))
        if timestamp.tzinfo is None:
            raise Refusal('invalid-observation-time')
        age = (dt.datetime.now(dt.timezone.utc) - timestamp).total_seconds()
        if not 0 <= age <= 300:
            raise Refusal('stale-inventory')
        objects = inventory.get('objects')
        if not isinstance(objects, list):
            raise Refusal('invalid-inventory')
        if not objects:
            raise Refusal('empty-inventory')
    except (Refusal, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        emit(machine, None, None, None, [str(error) if isinstance(error, Refusal) else 'invalid-inventory'])
        return 2
    refused = False
    for item in objects:
        reasons, facts = [], []
        if (not isinstance(item, dict) or not isinstance(item.get('path'), str)
                or not isinstance(item.get('kind'), str)
                or not isinstance(item.get('evidence', {}), dict)):
            emit(machine, None, None, provenance, ['invalid-object'])
            refused = True
            continue
        if item['kind'] not in POLICY[machine]:
            reasons.append('missing-whitelist')
        elif item['kind'] == 'docker-image':
            unused(item, None, facts, reasons)
            docker(item, facts, reasons)
        else:
            path = inspect_path(item, reasons, facts)
            if path is not None:
                unused(item, path, facts, reasons)
                category(item, path, facts, reasons)
        emit(machine, item['path'], item['kind'], provenance, reasons, facts)
        refused = refused or bool(reasons)
    return 2 if refused else 0


if __name__ == '__main__':
    sys.exit(main())
