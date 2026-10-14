#!/usr/bin/env bash
# Public read-only eligibility with real Git diffs and isolated forge/native evidence.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
export FM_AUTO_TEST_ROOT="$ROOT"
python3 - "$@" <<'PY'
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['FM_AUTO_TEST_ROOT'])
URL = 'https://github.com/example/repo/pull/7'

FORGE = '''#!/usr/bin/env python3
import base64,json,os,sys
from pathlib import Path
w=Path(os.environ['FM_AUTO_WORLD'])
a=sys.argv[1:]
with (w/'calls').open('a') as f: f.write(json.dumps([Path(sys.argv[0]).name]+a)+'\\n')
d=json.loads((w/'evidence').read_text())
if Path(sys.argv[0]).name=='no-mistakes':
    print((w/'native').read_text()); sys.exit(0)
if Path(sys.argv[0]).name=='gh':
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

GATE = '''#!/usr/bin/env bash
set -eu
[ "${FM_AUTO_GATE_FAIL:-0}" = 0 ] || exit "$FM_AUTO_GATE_FAIL"
if [ -n "${FM_AUTO_GATE_OUTPUT:-}" ]; then printf '%s\\n' "$FM_AUTO_GATE_OUTPUT"; exit; fi
s=$(git diff --numstat "$1" "$2" | awk '{a+=$1;d+=$2;f++} END {printf "added=%d deleted=%d lines=%d files=%d max_lines=400 max_files=15",a,d,a+d,f}')
printf '%s\\n' "$s"
'''

class Eligibility(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fm-auto-eligibility-')
        self.addCleanup(self.temp.cleanup)
        self.w = Path(self.temp.name)
        self.repo = self.w/'repo'
        self.repo.mkdir()
        self.tool = self.w/'tool'
        (self.tool/'bin').mkdir(parents=True)
        for name in ('fm-auto-merge-check.sh','fm_auto_merge_check.py',
                     'fm-auto-merge-denylist.globs',
                     'fm-pr-lib.sh','fm-cli-lib.sh','fm-nm-run-lib.sh'):
            src = ROOT/'bin'/name
            if src.exists(): shutil.copy2(src, self.tool/'bin'/name)
        gate = self.tool/'bin/size-gate.sh'
        gate.write_text(GATE); gate.chmod(0o755)
        fakebin = self.w/'fakebin'; fakebin.mkdir()
        for name in ('gh','gh-axi','no-mistakes'):
            p=fakebin/name; p.write_text(FORGE); p.chmod(0o755)
        self.home=self.w/'home'
        (self.home/'state').mkdir(parents=True)
        self.env=dict(os.environ, FM_AUTO_WORLD=str(self.w), FM_HOME=str(self.home),
                      PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
        self.git('init','-q','-b','topic')
        self.git('config','user.name','Fixture')
        self.git('config','user.email','fixture@example.invalid')
        (self.repo/'docs').mkdir()
        self.path='docs/intro.md'
        self.set_change('A useful sentence.  \n','A useful sentence.\n')

    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.repo),*args],text=True).strip()

    def set_change(self,before,after,path=None):
        path=path or self.path
        self.git('reset','--hard','-q') if (self.repo/'.git/HEAD').exists() and self.git('rev-list','--all','--count')!='0' else None
        p=self.repo/path; p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(before.encode() if isinstance(before,str) else before)
        self.git('add','--',path); self.git('commit','--allow-empty','-qm','Base')
        self.base=self.git('rev-parse','HEAD')
        p.write_bytes(after.encode() if isinstance(after,str) else after)
        self.git('add','--',path); self.git('commit','-qm','Presentation')
        self.head=self.git('rev-parse','HEAD')
        self.refresh()

    def refresh(self):
        fields=self.git('diff','--numstat','--no-renames',self.base,self.head).splitlines()
        files=[]
        statuses={row.split('\t',1)[1]:row[0] for row in self.git('diff','--name-status','--no-renames',self.base,self.head).splitlines()}
        for row in fields:
            a,d,path=row.split('\t')
            status={'M':'modified','A':'added','D':'removed'}.get(statuses[path],'unknown')
            blob_ref=self.base if status=='removed' else self.head
            files.append({'filename':path,'status':status,
              'sha':self.git('rev-parse',f'{blob_ref}:{path}'),
              'additions':int(a) if a.isdigit() else 0,
              'deletions':int(d) if d.isdigit() else 0})
        self.d={'pr':{'state':'open','draft':False,'mergeable':True,'mergeable_state':'clean',
          'head':{'sha':self.head,'ref':'topic'},'base':{'sha':self.base},
          'user':{'id':10,'login':'author'},'changed_files':len(files),
          'additions':sum(f['additions'] for f in files),'deletions':sum(f['deletions'] for f in files)},
          'merger':{'id':20,'login':'merger'},'files':files,
          'checks':[{'__typename':'CheckRun','name':f'check-{i}','status':'COMPLETED',
            'id':f'check-id-{i}','conclusion':'SUCCESS','checkSuite':{'headSha':self.head}} for i in range(101)]}
        self.native=f'''run:
  id: fixture-run
  branch: topic
  status: completed
  head: "{self.head}"
  pr: "{URL}"
  findings: none
outcome: passed
steps[2]{{step,status,findings,duration_ms}}:
  review,completed,0,12
  ci,completed,0,12
'''
        meta=self.home/'state/task.meta'
        meta.write_text(f'worktree={self.repo}\nmode=no-mistakes\npr={URL}\npr_head={self.head}\n')
        meta.chmod(0o600)

    def run_check(self,ok=True,reason=None):
        (self.w/'evidence').write_text(json.dumps(self.d))
        (self.w/'native').write_text(self.native)
        for name in ('reads','calls'):
            (self.w/name).unlink(missing_ok=True)
        before=self.git('status','--porcelain=v1'),self.git('show-ref')
        home_before={str(p.relative_to(self.home)):p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        cmd=self.tool/'bin/fm-auto-merge-check.sh'
        self.assertTrue(cmd.exists(),'missing public eligibility command')
        out=subprocess.run(['bash',str(cmd),'task',URL],env=self.env,text=True,capture_output=True)
        self.assertEqual(out.returncode==0,ok,out.stdout+out.stderr)
        if reason: self.assertIn(reason,out.stderr)
        self.assertEqual(before,(self.git('status','--porcelain=v1'),self.git('show-ref')))
        self.assertEqual(home_before,{str(p.relative_to(self.home)):p.read_bytes() for p in self.home.rglob('*') if p.is_file()})
        calls=[json.loads(s) for s in (self.w/'calls').read_text().splitlines()] if (self.w/'calls').exists() else []
        self.assertFalse(any('merge' in c or 'run' in c or 'respond' in c for c in calls),calls)
        if not ok: self.assertEqual(out.stdout,'','refusal leaked success-shaped evidence')
        return out,calls

    def test_accepts_presentation_diff_and_all_101_checks(self):
        out,calls=self.run_check()
        result=json.loads(out.stdout)
        self.assertEqual(result['head'],self.head)
        self.assertEqual(result['base'],self.base)
        self.assertEqual(result['files'],1)
        self.assertEqual(result['lines'],2)
        self.assertEqual(result['merger_id'],20)
        self.assertGreaterEqual(sum(c[1:4]==['api','POST','/graphql'] for c in calls),2)

    def test_late_page_red_is_not_ignored(self):
        self.d['checks'][-1]['conclusion']='FAILURE'
        self.run_check(False,'checks')

    def test_check_refusals(self):
        original=json.loads(json.dumps(self.d))
        for kind in ('zero','old-head','pending','unknown','malformed','neutral','incomplete','cursor','duplicate','bad-name'):
            with self.subTest(kind=kind):
                self.d=json.loads(json.dumps(original))
                if kind=='zero': self.d['checks']=[]
                if kind=='old-head': self.d['checks'][0]['checkSuite']['headSha']=self.base
                if kind=='pending': self.d['checks'][0]['status']='IN_PROGRESS'
                if kind=='unknown': self.d['checks'][0]['__typename']='Other'
                if kind=='malformed': self.d['checks'][0].pop('name')
                if kind=='neutral': self.d['checks'][0]['conclusion']='NEUTRAL'
                if kind=='incomplete': self.d['connection']={'totalCount':102}
                if kind=='cursor': self.d['connection']={'pageInfo':{'hasNextPage':True,'endCursor':None}}
                if kind=='duplicate': self.d['checks'][-1]=self.d['checks'][0]
                if kind=='bad-name': self.d['checks'][0]['name']={'not':'a name'}
                self.run_check(False)
                self.d=original

    def test_head_state_identity_and_file_evidence_refusals(self):
        original=json.loads(json.dumps(self.d))
        for kind in ('dirty','unknown','draft','closed','same-id','same-login','missing-id',
                     'different-tools','check-head','file-sha','file-stats','file-count','renamed','removed','drift'):
            with self.subTest(kind=kind):
                self.d=json.loads(json.dumps(original))
                if kind=='dirty': self.d['pr']['mergeable_state']='dirty'
                if kind=='unknown': self.d['pr']['mergeable']=None
                if kind=='draft': self.d['pr']['draft']=True
                if kind=='closed': self.d['pr']['state']='closed'
                if kind=='same-id': self.d['merger']['id']=10
                if kind=='same-login': self.d['merger']['login']='AUTHOR'
                if kind=='missing-id': self.d['merger'].pop('id')
                if kind=='different-tools': self.d['raw_merger']={'id':30,'login':'different'}
                if kind=='check-head': self.d['check_head']=self.base
                if kind=='file-sha': self.d['files'][0]['sha']=self.base
                if kind=='file-stats': self.d['files'][0]['deletions']=0
                if kind=='file-count': self.d['pr']['changed_files']=2
                if kind in ('renamed','removed'): self.d['files'][0]['status']=kind
                if kind=='drift':
                    self.d['final_pr']=json.loads(json.dumps(self.d['pr']))
                    self.d['final_pr']['head']['sha']=self.base
                self.run_check(False)
                self.d=original

    def test_size_gate_is_mandatory_and_strict(self):
        for output in ('bad','added=1 deleted=1 lines=2 files=1 max_lines=500 max_files=15',
                       'added=1 deleted=1 lines=401 files=1 max_lines=400 max_files=15',
                       'added=1 deleted=1 lines=2 files=16 max_lines=400 max_files=15'):
            with self.subTest(output=output):
                self.env['FM_AUTO_GATE_OUTPUT']=output
                self.run_check(False,'size')
        self.env.pop('FM_AUTO_GATE_OUTPUT')
        for rc in ('1','2'):
            self.env['FM_AUTO_GATE_FAIL']=rc; self.run_check(False,'size')
        self.env.pop('FM_AUTO_GATE_FAIL')
        (self.tool/'bin/size-gate.sh').unlink()
        self.run_check(False,'size')

    def test_native_proof_refusals(self):
        orig=self.native
        for old,new in ((self.head,self.base),('branch: topic','branch: other'),
          (URL,URL+'0'),('findings: none','findings: unknown'),
          ('review,completed,0','review,completed,1'),('review,completed','review,skipped'),
          ('outcome: passed','outcome: failed'),('status: completed','status: fixing'),
          ('steps[2]','steps[3]')):
            with self.subTest(new=new):
                self.native=orig.replace(old,new)
                self.run_check(False,'native'); self.native=orig

    def test_native_branch_sync_heads_do_not_replace_run_identity(self):
        self.native+='''branch_sync:
  state: synchronized
  local:
    branch: topic
    head: stale-local-detail
  pipeline:
    head: stale-pipeline-detail
'''
        self.run_check()

    def test_native_pipeline_custody_is_not_approval(self):
        self.native+='branch_sync:\n  state: pipeline_owned\n'
        self.run_check(False,'native')

    def test_exactly_50_deleted_diff_lines_remain_eligible(self):
        self.set_change('Plain prose.  \n'*50,'Plain prose.\n'*50)
        self.run_check()

    def test_actual_removal_and_sensitive_rename_sources_refuse(self):
        self.git('reset','--hard','-q',self.base)
        source=self.repo/'bin/fm-worker-guard-secret.sh'
        source.parent.mkdir()
        source.write_text('Plain prose.  \n')
        self.git('add','.'); self.git('commit','-qm','Sensitive source')
        self.base=self.git('rev-parse','HEAD')
        self.git('mv','bin/fm-worker-guard-secret.sh','docs/moved.md')
        self.git('commit','-qm','Rename')
        self.head=self.git('rev-parse','HEAD'); self.refresh()
        self.run_check(False)
        self.git('reset','--hard','-q',self.base)
        self.git('rm',self.path); self.git('commit','-qm','Removal')
        self.head=self.git('rev-parse','HEAD'); self.refresh()
        self.run_check(False)

    def test_missing_forge_and_native_evidence_refuses(self):
        for key in ('checks','merger','files'):
            with self.subTest(key=key):
                old=self.d.pop(key)
                self.run_check(False)
                self.d[key]=old
        self.native=''
        self.run_check(False,'native')

    def test_accepts_docs_and_tests_non_executable_changes(self):
        for path in ('docs/intro.md','tests/example.test.sh'):
            with self.subTest(path=path):
                self.set_change('A useful sentence.\n','A different useful sentence.\n',path)
                self.run_check()

    def test_unchanged_executable_mode_refuses(self):
        self.git('reset','--hard','-q',self.base)
        script=self.repo/'tests/example.test.sh'
        script.parent.mkdir(parents=True,exist_ok=True)
        script.write_text('A useful sentence.\n')
        script.chmod(0o755)
        self.git('add','--','tests/example.test.sh')
        self.git('commit','-qm','Executable base')
        self.base=self.git('rev-parse','HEAD')
        script.write_text('A different useful sentence.\n')
        self.git('add','--','tests/example.test.sh')
        self.git('commit','-qm','Executable edit')
        self.head=self.git('rev-parse','HEAD'); self.refresh()
        self.run_check(False,'unclassified mode')

    def test_denylist_categories_refuse(self):
        for path in ('AGENTS.md','docs/AGENTS.md','.agents/skills/a.md',
                     '.github/workflows/ci.yml','.claude/settings.json','.codex/hooks.json',
                     '.grok/hooks/a.json','.pi/extensions/a.ts','.omp/fm-worker-overlay.yml',
                     'bin/fm-calm.sh','bin/fm-hook-host-lib.sh','bin/fm-cd-pretool-check.sh',
                     'bin/fm-cd-command-policy.mjs',
                     'bin/fm-pr-merge.sh','bin/fm-merge-local.sh','bin/fm-merge-authority-lib.sh',
                     'bin/fm-teardown.sh','bin/fm-spawn.sh','bin/fm-lock-lib.sh',
                     'bin/fm-wake-lib.sh','bin/fm-watch.sh','bin/size-gate.sh',
                     'bin/fm-worker-guard-pretool-check.sh','bin/fm-antidrift-check.sh',
                     'bin/fm-wip-lib.sh','bin/fm-auto-merge-check.sh',
                     'bin/fm_auto_merge_check.py','tests/fm-auto-merge-check.test.sh',
                     'bin/fm-install-shellcheck.sh','bin/fm-update.sh','bin/fm-bootstrap.sh',
                     'config/a.md','secrets/a.md','docs/credential.md','docs/token.md',
                     'docs/.env','docs/rights.md','docs/publication.md','docs/remote.md'):
            with self.subTest(path=path):
                self.set_change('A useful sentence.\n','A different useful sentence.\n',path)
                self.run_check(False,'sensitive path')

    def test_sensitive_diff_content_refuses(self):
        for before,after in (
            ('A useful sentence.\n','A useful sentence.\nGITHUB_TOKEN=ghp_example\n'),
            ('A useful sentence with a token.\n','A useful sentence.\n'),
            ('A useful sentence.\n','A changed sentence with a password.\n')):
            with self.subTest(after=after):
                self.set_change(before,after,'docs/setup.md')
                self.run_check(False,'sensitive content')

    def test_instruction_and_config_siblings_refuse(self):
        for path in ('CLAUDE.md','docs/CLAUDE.md','GROK_BOT.md','skills/stow/SKILL.md',
                     '.no-mistakes.yaml','.greptile/rules.md','.tasks.toml','.gitattributes'):
            with self.subTest(path=path):
                self.set_change('A useful sentence.\n','A different useful sentence.\n',path)
                self.run_check(False,'sensitive path')

    def test_symlink_addition_and_binary_refuse(self):
        self.git('reset','--hard','-q',self.base)
        (self.repo/'docs/new.md').write_text('A new sentence.\n')
        (self.repo/'docs/link.md').symlink_to('intro.md')
        self.git('add','--','docs/new.md','docs/link.md')
        self.git('commit','-qm','Addition and symlink')
        self.head=self.git('rev-parse','HEAD'); self.refresh(); self.run_check(False)
        self.set_change(b'Before\x00value\n',b'After\x00value\n'); self.run_check(False)

    def test_mode_change_and_large_deletion_refuse(self):
        self.set_change('A sentence.  \n'*51,'A sentence.\n'*51)
        self.run_check(False,'deletion')
        self.set_change('A sentence.  \n','A sentence.\n')
        self.git('update-index','--chmod=+x',self.path); self.git('commit','-qm','Executable')
        self.head=self.git('rev-parse','HEAD'); self.refresh(); self.run_check(False)

    def test_file_pagination_is_complete_even_when_size_excludes_paths(self):
        self.git('reset','--hard','-q',self.base)
        for i in range(101): (self.repo/'docs'/f'page{i}.md').write_text('Plain prose.  \n')
        self.git('add','.'); self.git('commit','-qm','Many base pages')
        self.base=self.git('rev-parse','HEAD')
        for i in range(101): (self.repo/'docs'/f'page{i}.md').write_text('Plain prose.\n')
        self.git('add','.'); self.git('commit','-qm','Many changed pages')
        self.head=self.git('rev-parse','HEAD'); self.refresh()
        self.env['FM_AUTO_GATE_OUTPUT']='added=0 deleted=0 lines=0 files=0 max_lines=400 max_files=15'
        _,calls=self.run_check(False,'deletion')
        self.assertTrue(any('files?per_page=100&page=2' in ' '.join(c) for c in calls))

unittest.main()
PY
