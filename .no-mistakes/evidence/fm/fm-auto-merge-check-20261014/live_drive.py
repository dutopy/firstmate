#!/usr/bin/env python3
"""Live end-to-end driver for the real bin/fm-auto-merge-check.sh product.

The product (wrapper + python + real denylist + real size-gate.sh) runs from the
worktree under test. GitHub and no-mistakes are pointed at a disposable local
forge/native stub through PATH and FM_HOME, while the diff is a real git diff in
a throwaway repository. Nothing outside the disposable world is written.
"""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PRODUCT = Path(sys.argv[1]).resolve()
URL = 'https://github.com/example/repo/pull/7'
WORLD = os.environ.get('FM_LIVE_WORLD')

FORGE = '''#!/usr/bin/env python3
import base64,json,os,sys
from pathlib import Path
w=Path(os.environ['FM_LIVE_WORLD'])
a=sys.argv[1:]
name=Path(sys.argv[0]).name
with (w/'calls').open('a') as f: f.write(json.dumps([name]+a)+'\\n')
d=json.loads((w/'evidence').read_text())
if name=='no-mistakes':
    print((w/'native').read_text()); sys.exit(0)
if name=='gh':
    if a!=['api','user','--hostname','github.com']: sys.exit(90)
    print(json.dumps(d.get('raw_merger',d['merger']))); sys.exit(0)
if a[:2]==['api','GET']:
    p=a[2]
    if p=='/user': out=d['merger']
    elif p=='/repos/example/repo/pulls/7':
        counter=w/'reads'
        n=int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(n+1))
        out=d.get('final_pr',d['pr']) if n else d['pr']
    elif p.startswith('/repos/example/repo/pulls/7/files?'):
        page=int(p.split('page=')[-1]); out=d['files'][(page-1)*100:page*100]
    else: sys.exit(91)
elif a[:3]==['api','POST','/graphql']:
    body=json.load(sys.stdin); after=body['variables'].get('after')
    page=0 if after is None else int(after)
    checks=d['checks'][page:page+100]; end=page+len(checks)
    connection={'nodes':checks,'totalCount':len(d['checks']),
      'pageInfo':{'hasNextPage':end<len(d['checks']),'endCursor':str(end)}}
    connection.update(d.get('connection',{}))
    out={'data':{'repository':{'pullRequest':{'headRefOid':d.get('check_head',d['pr']['head']['sha']),
      'statusCheckRollup':{'contexts':connection}}}}}
else: sys.exit(92)
print(base64.b64encode(json.dumps(out).encode()).decode())
'''


class World:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fm-auto-live-')
        self.w = Path(self.temp.name)
        self.repo = self.w / 'repo'
        self.repo.mkdir()
        self.home = self.w / 'home'
        (self.home / 'state').mkdir(parents=True)
        fakebin = self.w / 'fakebin'
        fakebin.mkdir()
        for name in ('gh', 'gh-axi', 'no-mistakes'):
            p = fakebin / name
            p.write_text(FORGE)
            p.chmod(0o755)
        self.env = dict(os.environ, FM_LIVE_WORLD=str(self.w), FM_HOME=str(self.home),
                        PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
        self.env.pop('FM_STATE_OVERRIDE', None)
        self.git('init', '-q', '-b', 'topic')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'docs').mkdir()
        self.path = 'docs/intro.md'
        self.set_change('A useful sentence.\n', 'A useful sentence.\nA second useful sentence.\n')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True).strip()

    def commit_all(self, message):
        self.git('add', '-A', '--', '.')
        self.git('commit', '-q', '-m', message)

    def set_change(self, before, after, path=None):
        path = path or self.path
        p = self.repo / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(before.encode() if isinstance(before, str) else before)
        self.commit_all('Base')
        self.base = self.git('rev-parse', 'HEAD')
        p.write_bytes(after.encode() if isinstance(after, str) else after)
        self.commit_all('Presentation')
        self.head = self.git('rev-parse', 'HEAD')
        self.refresh()

    def set_multi(self, paths, before='Start.\n', after='Changed start.\n'):
        for path in paths:
            p = self.repo / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(before)
        self.commit_all('Base')
        self.base = self.git('rev-parse', 'HEAD')
        for path in paths:
            (self.repo / path).write_text(after)
        self.commit_all('Presentation')
        self.head = self.git('rev-parse', 'HEAD')
        self.refresh()

    def refresh(self):
        fields = self.git('diff', '--numstat', '--no-renames', self.base, self.head).splitlines()
        statuses = {row.split('\t', 1)[1]: row[0]
                    for row in self.git('diff', '--name-status', '--no-renames', self.base, self.head).splitlines()}
        files = []
        for row in fields:
            a, d, path = row.split('\t')
            status = {'M': 'modified', 'A': 'added', 'D': 'removed'}.get(statuses[path], 'unknown')
            blob_ref = self.base if status == 'removed' else self.head
            files.append({'filename': path, 'status': status,
                          'sha': self.git('rev-parse', f'{blob_ref}:{path}'),
                          'additions': int(a) if a.isdigit() else 0,
                          'deletions': int(d) if d.isdigit() else 0})
        self.d = {'pr': {'state': 'open', 'draft': False, 'mergeable': True, 'mergeable_state': 'clean',
                         'head': {'sha': self.head, 'ref': 'topic'}, 'base': {'sha': self.base},
                         'user': {'id': 10, 'login': 'author'}, 'changed_files': len(files),
                         'additions': sum(f['additions'] for f in files),
                         'deletions': sum(f['deletions'] for f in files)},
                  'merger': {'id': 20, 'login': 'merger'}, 'files': files,
                  'checks': [{'__typename': 'CheckRun', 'name': f'check-{i}', 'status': 'COMPLETED',
                              'id': f'check-id-{i}', 'conclusion': 'SUCCESS',
                              'checkSuite': {'commit': {'oid': self.head}}} for i in range(101)]}
        self.native = ('run:\n'
                       '  id: fixture-run\n'
                       '  branch: topic\n'
                       '  status: completed\n'
                       f'  head: "{self.head}"\n'
                       f'  pr: "{URL}"\n'
                       '  findings: none\n'
                       'outcome: passed\n'
                       'steps[2]{step,status,findings,duration_ms}:\n'
                       '  review,completed,0,12\n'
                       '  ci,completed,0,12\n')
        meta = self.home / 'state/task.meta'
        meta.write_text(f'worktree={self.repo}\nmode=no-mistakes\npr={URL}\npr_head={self.head}\n')
        meta.chmod(0o600)

    def run(self):
        (self.w / 'evidence').write_text(json.dumps(self.d))
        (self.w / 'native').write_text(self.native)
        for name in ('reads', 'calls'):
            (self.w / name).unlink(missing_ok=True)
        repo_before = (self.git('status', '--porcelain=v1'), self.git('show-ref'))
        home_before = {str(p.relative_to(self.home)): p.read_bytes()
                       for p in self.home.rglob('*') if p.is_file()}
        proc = subprocess.run(['bash', str(PRODUCT / 'fm-auto-merge-check.sh'), 'task', URL],
                              env=self.env, text=True, capture_output=True)
        repo_after = (self.git('status', '--porcelain=v1'), self.git('show-ref'))
        home_after = {str(p.relative_to(self.home)): p.read_bytes()
                      for p in self.home.rglob('*') if p.is_file()}
        calls = [json.loads(s) for s in (self.w / 'calls').read_text().splitlines()] \
            if (self.w / 'calls').exists() else []
        return {'rc': proc.returncode, 'stdout': proc.stdout, 'stderr': proc.stderr,
                'repo_unchanged': repo_before == repo_after,
                'home_unchanged': home_before == home_after, 'calls': calls}


def summarize(w, r):
    return {'rc': r['rc'], 'stdout': r['stdout'].strip(), 'stderr': r['stderr'].strip(),
            'repo_unchanged': r['repo_unchanged'], 'home_unchanged': r['home_unchanged'],
            'head': w.head, 'base': w.base}


def main():
    results = {}

    def scenario(name, fn):
        w = World()
        try:
            results[name] = fn(w)
        finally:
            w.temp.cleanup()

    def eligible_accepts(w):
        r = w.run()
        return summarize(w, r)

    scenario('S1_eligible_docs_edit_accepts', eligible_accepts)

    def bin_fix_refuses(w):
        w.set_change('A useful sentence.\n', 'A better sentence.\n', 'bin/fm-calm.sh')
        return summarize(w, w.run())

    scenario('S2_bin_script_fix_refuses', bin_fix_refuses)

    def denylist_categories(w):
        cases = {}
        for path in ('AGENTS.md', 'docs/AGENTS.md', '.agents/skills/a.md',
                     '.github/workflows/ci.yml', '.claude/settings.json', '.codex/hooks.json',
                     '.grok/hooks/a.json', '.pi/extensions/a.ts', '.omp/overlay.yml',
                     'bin/fm-pr-merge.sh', 'bin/fm-merge-local.sh', 'bin/fm-teardown.sh',
                     'bin/fm-spawn.sh', 'bin/fm-lock-lib.sh', 'bin/fm-watch.sh',
                     'bin/size-gate.sh', 'config/a.md', 'secrets/a.md', 'docs/credential.md',
                     'docs/token.md', 'docs/.env', 'CLAUDE.md', 'docs/CLAUDE.md',
                     'GROK_BOT.md', 'skills/stow/SKILL.md', '.no-mistakes.yaml',
                     '.greptile/rules.md', '.tasks.toml', '.gitattributes'):
            w.set_change('A useful sentence.\n', 'A different useful sentence.\n', path)
            r = w.run()
            cases[path] = {'rc': r['rc'], 'empty_stdout': r['stdout'] == ''}
        return cases

    scenario('S3_denylist_categories_refuse', denylist_categories)

    def credential_content(w):
        cases = {}
        for label, after in (
                ('github_token', 'A useful sentence.\nGITHUB_TOKEN=ghp_example\n'),
                ('aws_access_key', 'A useful sentence.\nAWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n'),
                ('api_key', 'A useful sentence.\napi_key: sk-live-abc\n'),
                ('bearer', 'A useful sentence.\nAuthorization: Bearer eyJhbGci\n'),
                ('passwd', 'A useful sentence.\npasswd=foo\n'),
                ('private_key', 'A useful sentence.\n-----BEGIN RSA PRIVATE KEY-----\n')):
            w.set_change('A useful sentence.\n', after, 'docs/cloud.md')
            r = w.run()
            cases[label] = {'rc': r['rc'], 'stderr': r['stderr'].strip(), 'empty_stdout': r['stdout'] == ''}
        return cases

    scenario('S4_credential_like_content_refuses', credential_content)

    def executable_mode(w):
        out = {}
        # Unchanged executable mode on a non-bin path is still refused (mode gate).
        w.git('reset', '--hard', '-q')
        script = w.repo / 'tests/example.test.sh'
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text('A useful sentence.\n')
        script.chmod(0o755)
        w.commit_all('Executable base')
        w.base = w.git('rev-parse', 'HEAD')
        script.write_text('A different useful sentence.\n')
        w.commit_all('Executable edit')
        w.head = w.git('rev-parse', 'HEAD')
        w.refresh()
        r = w.run()
        out['unchanged_0755_refuses'] = {'rc': r['rc'], 'stderr': r['stderr'].strip()}

        # A real 100644 -> 100755 mode change is refused too.
        w2 = World()
        try:
            w2.set_change('A useful sentence.\n', 'A different useful sentence.\n', 'docs/intro.md')
            w2.git('update-index', '--chmod=+x', 'docs/intro.md')
            w2.git('commit', '-q', '-m', 'Mode change')
            w2.head = w2.git('rev-parse', 'HEAD')
            w2.refresh()
            r2 = w2.run()
            out['mode_change_refuses'] = {'rc': r2['rc'], 'stderr': r2['stderr'].strip()}
        finally:
            w2.temp.cleanup()
        return out

    scenario('S5_executable_file_refuses', executable_mode)

    def size_bounds(w):
        out = {}
        # A real modified file deleting 51 lines while still existing at head.
        w.set_change('A sentence.\n' * 51, 'short\n', 'docs/intro.md')
        r = w.run()
        out['deletion_gt_50_refuses'] = {'rc': r['rc'], 'stderr': r['stderr'].strip()}

        w2 = World()
        try:
            w2.set_change('Plain prose.  \n' * 50, 'Plain prose.\n' * 50, 'docs/intro.md')
            r2 = w2.run()
            out['exactly_50_deletions_accepts'] = {'rc': r2['rc'], 'stderr': r2['stderr'].strip()}
        finally:
            w2.temp.cleanup()

        w3 = World()
        try:
            w3.set_change('Start.\n', 'Start.\n' + 'Plain prose.\n' * 401, 'docs/big.md')
            r3 = w3.run()
            out['over_400_lines_refuses'] = {'rc': r3['rc'], 'stderr': r3['stderr'].strip()}
        finally:
            w3.temp.cleanup()

        w4 = World()
        try:
            w4.set_multi([f'docs/page{i}.md' for i in range(16)])
            r4 = w4.run()
            out['over_15_files_refuses'] = {'rc': r4['rc'], 'stderr': r4['stderr'].strip()}
        finally:
            w4.temp.cleanup()
        return out

    scenario('S6_size_and_deletion_bounds', size_bounds)

    def structural(w):
        out = {}
        # symlink + addition
        (w.repo / 'docs/new.md').write_text('A new sentence.\n')
        (w.repo / 'docs/link.md').symlink_to('intro.md')
        w.commit_all('Addition and symlink')
        w.head = w.git('rev-parse', 'HEAD')
        w.refresh()
        r = w.run()
        out['addition_and_symlink_refuse'] = {'rc': r['rc'], 'stderr': r['stderr'].strip()}

        w2 = World()
        try:
            w2.set_change(b'Before\x00value\n', b'After\x00value\n', 'docs/bin.md')
            r2 = w2.run()
            out['binary_refuses'] = {'rc': r2['rc'], 'stderr': r2['stderr'].strip()}
        finally:
            w2.temp.cleanup()
        return out

    scenario('S7_structural_changes_refuse', structural)

    def check_states(w):
        out = {}
        for label, mutate in (
                ('late_page_failure', lambda d: d['checks'][-1].__setitem__('conclusion', 'FAILURE')),
                ('pending', lambda d: d['checks'][0].__setitem__('status', 'IN_PROGRESS')),
                ('neutral', lambda d: d['checks'][0].__setitem__('conclusion', 'NEUTRAL')),
                ('old_commit_oid', lambda d: d['checks'][0]['checkSuite']['commit'].__setitem__('oid', d['pr']['base']['sha'])),
                ('zero_checks', lambda d: d.__setitem__('checks', []))):
            w.refresh()
            mutate(w.d)
            r = w.run()
            out[label] = {'rc': r['rc'], 'stderr': r['stderr'].strip(), 'empty_stdout': r['stdout'] == ''}
        return out

    scenario('S8_non_green_final_head_refuses', check_states)

    def identity_and_state(w):
        out = {}
        for label, mutate in (
                ('author_equals_merger', lambda d: d['merger'].__setitem__('id', 10)),
                ('dirty_merge_state', lambda d: d['pr'].__setitem__('mergeable_state', 'dirty')),
                ('draft', lambda d: d['pr'].__setitem__('draft', True))):
            w.refresh()
            mutate(w.d)
            r = w.run()
            out[label] = {'rc': r['rc'], 'stderr': r['stderr'].strip()}
        return out

    scenario('S9_identity_and_pr_state_refuse', identity_and_state)

    def native_contract(w):
        out = {}
        monitoring = ('run:\n  id: fixture-run\n  branch: topic\n  status: running\n'
                      f'  head: "{w.head}"\n  head_sha: "{w.head}"\n  pr: "{URL}"\n  findings: none\n'
                      'steps[3]{step,status,findings,duration_ms}:\n'
                      '  review,completed,0,12\n  pr,completed,0,12\n  ci,running,0,12\n')
        w.native = monitoring
        r = w.run()
        out['ci_ready_monitoring_accepts'] = {'rc': r['rc'], 'stderr': r['stderr'].strip()}

        for label, text in (('active_fixer_refuses', monitoring.replace('status: running', 'status: fixing')),
                            ('pipeline_owned_refuses', monitoring + 'branch_sync:\n  state: pipeline_owned\n')):
            w.native = text
            r = w.run()
            out[label] = {'rc': r['rc'], 'stderr': r['stderr'].strip(), 'empty_stdout': r['stdout'] == ''}

        for label, text in (('open_findings_refuses', monitoring.replace('findings: none', 'findings: 1 awaiting')),
                            ('missing_native_refuses', '')):
            w.native = text
            r = w.run()
            out[label] = {'rc': r['rc'], 'stderr': r['stderr'].strip(), 'empty_stdout': r['stdout'] == ''}
        return out

    scenario('S10_native_review_contract', native_contract)

    def read_only(w):
        # refusal path: no repo/home writes, stdout empty
        w.set_change('A useful sentence.\n', 'A different useful sentence.\n', 'bin/fm-pr-merge.sh')
        r = w.run()
        merge_calls = [c for c in r['calls'] if any(k in c for k in ('merge', 'run', 'respond'))]
        return {'rc': r['rc'], 'repo_unchanged': r['repo_unchanged'],
                'home_unchanged': r['home_unchanged'], 'empty_stdout': r['stdout'] == '',
                'no_mutating_calls': not merge_calls}

    scenario('S11_read_only_refusal', read_only)

    out = Path('/Users/pierre/.no-mistakes/evidence/01M4YFY6NZ6R9BZD305JY2BCP3/live_results.json')
    out.write_text(json.dumps(results, indent=2, sort_keys=True))
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
