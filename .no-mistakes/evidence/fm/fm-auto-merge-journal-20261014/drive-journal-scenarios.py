#!/usr/bin/env python3
"""Drive fm-pr-merge.sh and the journal writer against a disposable forge."""
import base64
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

WORKTREE = Path('/Users/pierre/.no-mistakes/worktrees/152fa2a6a341/01M4ZHP2AYRVZGQ8SH7HRCVRSA')
EVIDENCE = Path('/Users/pierre/.no-mistakes/evidence/01M4ZHP2AYRVZGQ8SH7HRCVRSA')
URL = 'https://github.com/example/repo/pull/7'
PARENT = '35498b4691660a5ce83fd824d6c06a1cf3dbdf05'
FIXTURES = WORKTREE / 'tests/fixtures/auto-merge-journal'

spec = importlib.util.spec_from_file_location('journal_run', FIXTURES / 'run.py')
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

results = []


def record(name, ok, detail):
    results.append({'name': name, 'ok': ok, 'detail': detail})
    print(('PASS' if ok else 'FAIL') + ' ' + name)
    print(detail.rstrip())
    print('---')


def decode(path):
    return json.loads(base64.b64decode(Path(path).read_text().strip()))


def encode(path, obj):
    Path(path).write_text(base64.b64encode(json.dumps(obj).encode()).decode() + '\n')


def calls_text(case):
    path = case.world / 'calls'
    return path.read_text() if path.is_file() else ''


def forge_merged(case):
    return '"pr", "merge"' in calls_text(case)


def checker_ran(case):
    return '"no-mistakes"' in calls_text(case)


def authority_version(case):
    path = case.state / 'task.merge-authority'
    if not path.is_file():
        return 'absent'
    return path.read_text().splitlines()[0]


def open_case(root=None):
    previous = run.ROOT
    if root is not None:
        run.ROOT = root
    case = run.Journal(methodName='test_confirmed_automatic_merge_and_idempotence')
    case.setUp()
    case._previous_root = previous
    return case


def close_case(case):
    case.doCleanups()
    run.ROOT = case._previous_root


def overlay(replacements):
    root = Path(tempfile.mkdtemp(prefix='fm-journal-overlay-'))
    bindir = root / 'bin'
    bindir.mkdir()
    for item in (WORKTREE / 'bin').iterdir():
        dest = bindir / item.name
        if item.name in replacements:
            dest.write_bytes(replacements[item.name])
            dest.chmod(0o755)
        else:
            dest.symlink_to(item)
    shutil.copy2(WORKTREE / '.tasks.toml', root / '.tasks.toml')
    return root


def git_show(rev, path):
    return subprocess.check_output(['git', '-C', str(WORKTREE), 'show', f'{rev}:{path}'])


def retarget(case, head, base, files, changed):
    fixtures = Path(tempfile.mkdtemp(prefix='fm-journal-fixtures-'))
    shutil.copytree(FIXTURES, fixtures, dirs_exist_ok=True)
    pr = decode(fixtures / 'pr.b64')
    pr['head']['sha'] = head
    pr['base']['sha'] = base
    pr['changed_files'] = changed
    pr['additions'] = changed
    pr['deletions'] = changed
    encode(fixtures / 'pr.b64', pr)
    encode(fixtures / 'files.b64', files)
    for name in ('mergeable.b64', 'checks.b64', 'landed.b64'):
        raw = (fixtures / name).read_bytes()
        text = base64.b64decode(raw.strip()).decode()
        text = text.replace(run.HEAD, head)
        (fixtures / name).write_text(base64.b64encode(text.encode()).decode() + '\n')
    native = (fixtures / 'native.toon').read_text().replace(run.HEAD, head)
    (fixtures / 'native.toon').write_text(native)
    (fixtures / 'head.sha').write_text(head + '\n')
    case.env['FM_JOURNAL_FIXTURES'] = str(fixtures)
    meta = case.state / 'task.meta'
    meta.write_text(meta.read_text().replace(f'pr_head={run.HEAD}', f'pr_head={head}'))
    meta.chmod(0o600)
    return fixtures


def rebuild(case, paths):
    shutil.rmtree(case.repo)
    case.repo.mkdir()
    case.git('init', '-q', '-b', 'topic')
    case.git('config', 'user.name', 'Fixture')
    case.git('config', 'user.email', 'fixture@example.invalid')
    case.git('config', 'commit.gpgsign', 'false')
    case.git('config', 'core.autocrlf', 'false')
    for path, before in paths:
        target = case.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(before)
    case.git('add', '.')
    case.git('commit', '-qm', 'Base')
    base = case.git('rev-parse', 'HEAD')
    for path, _before in paths:
        (case.repo / path).write_text('A useful sentence.\n')
    case.git('add', '.')
    case.git('commit', '-qm', 'Presentation')
    head = case.git('rev-parse', 'HEAD')
    files = []
    for path, _before in paths:
        files.append({
            'filename': path,
            'status': 'modified',
            'sha': case.git('rev-parse', f'{head}:{path}'),
            'additions': 1,
            'deletions': 1,
        })
    return base, head, files


def scenario_pre_fix_zero_loses_journal():
    root = overlay({
        'fm-pr-merge.sh': git_show(PARENT, 'bin/fm-pr-merge.sh'),
        'fm-merge-authority-lib.sh': git_show(PARENT, 'bin/fm-merge-authority-lib.sh'),
    })
    case = open_case(root)
    try:
        case.bind_excluded_note()
        result = case.merge()
        detail = (
            f'rc={result.returncode}\n'
            f'accepted={ (case.world / "accepted").exists() }\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'journal={case.journal()}\n'
            f'authority={authority_version(case)}\n'
            f'stderr={result.stderr.strip()}\n'
            f'stdout={result.stdout.strip()}'
        )
        ok = (result.returncode != 0 and (case.world / 'accepted').exists()
              and forge_merged(case) and case.journal() == []
              and authority_version(case) == 'absent'
              and 'could not be persisted' in result.stderr)
        record('pre-fix zero-file merge is accepted then loses its journal', ok, detail)
    finally:
        close_case(case)
        shutil.rmtree(root)


def scenario_current_zero_journals():
    case = open_case()
    try:
        case.bind_excluded_note()
        result = case.merge()
        row = f'{URL}\t{run.ZERO_HEAD}\t0\t0\t2026-10-15T12:30:00Z'
        detail = (
            f'rc={result.returncode}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'checker_ran={checker_ran(case)}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'journal={case.journal()}\n'
            f'authority={authority_version(case)}\n'
            f'stdout={result.stdout.strip()}\n'
            f'stderr={result.stderr.strip()}'
        )
        ok = (result.returncode == 0 and checker_ran(case) and forge_merged(case)
              and case.journal() == [row] and authority_version(case) == 'fm-merge-authority-v2')
        record('current zero-file automatic merge journals the bound receipt', ok, detail)
        (EVIDENCE / 'zero-file-journal.tsv').write_text('\n'.join(case.journal()) + '\n')
    finally:
        close_case(case)


def scenario_head_mismatch_stops_before_forge():
    case = open_case()
    fixtures = Path(tempfile.mkdtemp(prefix='fm-journal-fixtures-'))
    try:
        shutil.copytree(FIXTURES, fixtures, dirs_exist_ok=True)
        mergeable = decode(fixtures / 'mergeable.b64')
        mergeable['headRefOid'] = '0123456789abcdef0123456789abcdef01234567'
        encode(fixtures / 'mergeable.b64', mergeable)
        case.env['FM_JOURNAL_FIXTURES'] = str(fixtures)
        result = case.merge()
        detail = (
            f'rc={result.returncode}\n'
            f'checker_ran={checker_ran(case)}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'journal={case.journal()}\n'
            f'authority={authority_version(case)}\n'
            f'stderr={result.stderr.strip()}'
        )
        ok = (result.returncode != 0 and checker_ran(case) and not forge_merged(case)
              and not (case.world / 'accepted').exists() and case.journal() == [])
        record('mismatched snapshot head is refused before the forge merge', ok, detail)
    finally:
        close_case(case)
        shutil.rmtree(fixtures)


def scenario_stub_bound(name, lines, files, expect_merge):
    snapshot = json.dumps({
        'url': URL,
        'head': run.HEAD,
        'lines': lines,
        'files': files,
    })
    stub = ('#!/bin/bash\nprintf "%s\\n" "$FM_STUB_SNAPSHOT"\n'
            'printf stub-called >> "$FM_JOURNAL_WORLD/stub-called"\n').encode()
    root = overlay({'fm-auto-merge-check.sh': stub})
    case = open_case(root)
    try:
        case.env['FM_STUB_SNAPSHOT'] = snapshot
        result = case.merge()
        expected = [f'{URL}\t{run.HEAD}\t{lines}\t{files}\t2026-10-15T12:30:00Z']
        detail = (
            f'snapshot={snapshot}\n'
            f'rc={result.returncode}\n'
            f'stub_called={(case.world / "stub-called").exists()}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'journal={case.journal()}\n'
            f'stderr={result.stderr.strip()}\n'
            f'stdout={result.stdout.strip()}'
        )
        if expect_merge:
            ok = (result.returncode == 0 and forge_merged(case)
                  and case.journal() == expected)
        else:
            ok = (result.returncode != 0 and (case.world / 'stub-called').exists()
                  and not forge_merged(case) and not (case.world / 'accepted').exists()
                  and case.journal() == [])
        record(name, ok, detail)
    finally:
        close_case(case)
        shutil.rmtree(root)


def scenario_deny_list():
    case = open_case()
    fixtures = None
    try:
        base, head, files = rebuild(case, [('bin/note.sh', 'A useful sentence.  \n')])
        fixtures = retarget(case, head, base, files, 1)
        result = case.merge()
        detail = (
            f'rc={result.returncode}\n'
            f'checker_ran={checker_ran(case)}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'journal={case.journal()}\n'
            f'stderr={result.stderr.strip()}'
        )
        ok = (result.returncode != 0 and checker_ran(case) and not forge_merged(case)
              and not (case.world / 'accepted').exists() and case.journal() == []
              and 'sensitive path' in result.stderr)
        record('deny-listed bin edit is refused before the forge merge', ok, detail)
    finally:
        close_case(case)
        if fixtures is not None:
            shutil.rmtree(fixtures)


def scenario_sixteen_files():
    case = open_case()
    fixtures = None
    try:
        paths = [(f'docs/page{i}.md', 'A useful sentence.  \n') for i in range(16)]
        base, head, files = rebuild(case, paths)
        gate = subprocess.run(
            [str(WORKTREE / 'bin/size-gate.sh'), base, head],
            cwd=case.repo, env=case.env, capture_output=True, text=True)
        fixtures = retarget(case, head, base, files, 16)
        result = case.merge()
        detail = (
            f'size-gate rc={gate.returncode} out={gate.stdout.strip()} err={gate.stderr.strip()}\n'
            f'merge rc={result.returncode}\n'
            f'checker_ran={checker_ran(case)}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'journal={case.journal()}\n'
            f'stderr={result.stderr.strip()}'
        )
        ok = (gate.returncode == 1 and 'files=16' in gate.stdout
              and result.returncode != 0 and checker_ran(case)
              and not forge_merged(case) and case.journal() == []
              and 'size gate' in result.stderr)
        record('sixteen counted files stay ineligible and never reach the forge', ok, detail)
        (EVIDENCE / 'size-gate-sixteen.txt').write_text(gate.stdout + gate.stderr)
    finally:
        close_case(case)
        if fixtures is not None:
            shutil.rmtree(fixtures)


def scenario_gitlab_refused():
    case = open_case()
    try:
        result = case.command(
            'fm-pr-merge.sh', 'task',
            'https://gitlab.com/example/repo/-/merge_requests/7', '--automatic')
        detail = (
            f'rc={result.returncode}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'calls={calls_text(case).strip()}\n'
            f'stderr={result.stderr.strip()}'
        )
        ok = (result.returncode == 2 and not forge_merged(case)
              and calls_text(case) == ''
              and 'GitHub without overrides' in result.stderr)
        record('GitLab --automatic is refused before any forge call', ok, detail)
    finally:
        close_case(case)


def scenario_attended_recovery_does_not_journal():
    case = open_case()
    try:
        merged = case.merge(automatic=False)
        recovered = case.recover()
        detail = (
            f'merge rc={merged.returncode} recover rc={recovered.returncode}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'authority={authority_version(case)}\n'
            f'journal={case.journal()}\n'
            f'recover stderr={recovered.stderr.strip()}'
        )
        ok = (merged.returncode == 0 and recovered.returncode == 0
              and (case.world / 'accepted').exists()
              and authority_version(case) == 'fm-merge-authority-v1'
              and case.journal() == [])
        record('attended merge and its poll recovery write no journal row', ok, detail)
    finally:
        close_case(case)


def scenario_conflicting_receipt():
    case = open_case()
    try:
        merged = case.merge()
        path = case.home / 'data/auto-merge-journal.tsv'
        original = path.read_text()
        conflict = original.replace(run.HEAD, '0123456789abcdef0123456789abcdef01234567')
        path.write_text(conflict)
        recovered = case.recover()
        detail = (
            f'merge rc={merged.returncode} recover rc={recovered.returncode}\n'
            f'journal_after_conflict={path.read_text().splitlines()}\n'
            f'recover stderr={recovered.stderr.strip()}'
        )
        ok = (recovered.returncode != 0 and path.read_text() == conflict
              and path.read_text() != original)
        record('poll recovery rejects a conflicting receipt for the same URL', ok, detail)
    finally:
        close_case(case)


def scenario_checker_does_not_merge():
    case = open_case()
    try:
        result = case.command('fm-auto-merge-check.sh', 'task', URL)
        detail = (
            f'rc={result.returncode}\n'
            f'stdout={result.stdout.strip()}\n'
            f'forge_merge_called={forge_merged(case)}\n'
            f'accepted={(case.world / "accepted").exists()}\n'
            f'journal={case.journal()}\n'
            f'authority={authority_version(case)}'
        )
        proof = json.loads(result.stdout)
        ok = (result.returncode == 0 and not forge_merged(case)
              and not (case.world / 'accepted').exists() and case.journal() == []
              and proof['files'] == 1 and proof['lines'] == 2 and proof['head'] == run.HEAD)
        record('eligibility check alone does not merge or journal', ok, detail)
    finally:
        close_case(case)


if __name__ == '__main__':
    scenario_pre_fix_zero_loses_journal()
    scenario_current_zero_journals()
    scenario_head_mismatch_stops_before_forge()
    scenario_stub_bound('files=16 snapshot is refused before the forge merge', 2, 16, False)
    scenario_stub_bound('files=15 snapshot remains inside the B1 bound and is journaled', 2, 15, True)
    scenario_stub_bound('lines=401 snapshot is refused before the forge merge', 401, 1, False)
    scenario_stub_bound('lines=400 snapshot remains inside the B1 bound and is journaled', 400, 1, True)
    scenario_deny_list()
    scenario_sixteen_files()
    scenario_gitlab_refused()
    scenario_attended_recovery_does_not_journal()
    scenario_conflicting_receipt()
    scenario_checker_does_not_merge()
    failed = [item['name'] for item in results if not item['ok']]
    summary = {'failed': failed, 'results': results}
    (EVIDENCE / 'adversarial-results.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('FAILED' if failed else 'ALL ADVERSARIAL SCENARIOS PASSED')
    if failed:
        raise SystemExit(1)
