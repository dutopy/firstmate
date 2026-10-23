import os, pathlib, shutil, subprocess, json
root = pathlib.Path.cwd()
base = root / '.test-phase-tmp/live'
base.mkdir(exist_ok=True)
evidence = pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M5M3VXTJ16AYP7T1V2RR6XK9/teardown-live-transcript.json')
tmux = shutil.which('tmux')
ps = shutil.which('ps')
packet = '''root_cause: stale cache key
regression_test: isolated completion cleanup reproduction
retest: cleanup retried after repairing the packet
authoritative_state: task metadata and endpoint checked after invocation
artifact_or_scope: disposable task t1
rollback: restore disposable task records
'''
cases = [
 ('missing-packet-force', True, None, 'done: ready\n', False),
 ('placeholder-force', True, packet.replace('rollback: restore disposable task records', 'rollback: TODO'), 'done: ready\n', False),
 ('padded-placeholder-force', True, packet.replace('rollback: restore disposable task records', 'rollback: \tunknown \t'), 'done: ready\n', False),
 ('crlf-workaround-force', True, (packet+'status: workaround \t\n').replace('\n','\r\n'), 'done: ready\n', False),
 ('continuation-cannot-hide-done', True, None, 'done: PR https://example.invalid/pr/1\n checks green\n', False),
 ('keyed-indented-done', True, None, ' \tdone [key=fix]: ready\n checks green\n', False),
 ('complete-packet-cleans-endpoint', True, packet, 'done: ready\n', True),
 ('complete-crlf-packet-cleans-endpoint', True, packet.replace('\n','\r\n'), 'done [key=fix]: ready\n checks green\n', True),
 ('non-optin-needs-no-packet', False, None, 'done: ready\n', True),
 ('later-working-event-needs-no-packet', True, None, 'done: ready\nworking: follow-up\n continuation\n', True),
]
records=[]
for name, required, proof, status, accept in cases:
 d=base/name
 for sub in ['home/state','home/config','home/data/t1','project','fakebin','userhome']:
  (d/sub).mkdir(parents=True,exist_ok=True)
 env=os.environ.copy()
 for k in list(env):
  if k.startswith('FM_') or k in ['TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
   env.pop(k,None)
 env.update(HOME=str(d/'userhome'), TMPDIR=str(root/'.test-phase-tmp'), GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
 socket='dedicated.sock'
 def t(*args):
  return subprocess.run([tmux,'-S',socket,*args],cwd=d,env=env,text=True,capture_output=True)
 try:
  subprocess.run(['git','init','-q',str(d/'project')],env=env,check=True)
  assert t('-f','/dev/null','new-session','-d','-s','proof','-n','control','sleep 120').returncode==0
  assert t('new-window','-d','-t','proof:','-n','fm-t1','sleep 120').returncode==0
  (d/'fakebin/tmux').write_text(f'#!/bin/bash\ncd "{d}" || exit 1\nexec "{tmux}" -S "{socket}" "$@"\n')
  (d/'fakebin/ps').write_text(f'#!/bin/bash\n[ "${{1:-}}" != -u ] || exit 0\nexec "{ps}" "$@"\n')
  for p in (d/'fakebin').iterdir(): p.chmod(0o755)
  (d/'home/config/backlog-backend').write_text('manual\n')
  meta=d/'home/state/t1.meta'
  meta.write_text(f'kind=ship\nmode=local-only\nwindow=proof:fm-t1\nendpoint_task_id=t1\nproject={d}/project\nworktree={d}/worktree\n'+('proof=required\n' if required else ''))
  (d/'home/state/t1.status').write_text(status)
  if proof is not None: (d/'home/data/t1/done-proof.md').write_bytes(proof.encode())
  def snapshot():
   return {str(p.relative_to(d/'home')):p.read_bytes().hex() for p in (d/'home').rglob('*') if p.is_file()}
  before=snapshot()
  before_windows=t('list-windows','-t','proof','-F','#{window_name}').stdout.splitlines()
  env.update(FM_HOME=str(d/'home'),FM_ROOT_OVERRIDE=str(root),FM_STATE_OVERRIDE=str(d/'home/state'),FM_DATA_OVERRIDE=str(d/'home/data'),FM_CONFIG_OVERRIDE=str(d/'home/config'),FM_GATE_REFUSE_BYPASS='1',PATH=str(d/'fakebin')+os.pathsep+env['PATH'])
  command=[str(root/'bin/fm-teardown.sh'),'t1','--force']
  out=subprocess.run(command,env=env,text=True,capture_output=True,timeout=35)
  after_windows=t('list-windows','-t','proof','-F','#{window_name}').stdout.splitlines()
  unchanged=before==snapshot()
  ok=(out.returncode==0 and not meta.exists() and after_windows==['control']) if accept else (out.returncode!=0 and 'requires a done proof packet' in out.stderr and unchanged and before_windows==after_windows)
  records.append(dict(scenario=name,command='FM_HOME=<isolated-home> bin/fm-teardown.sh t1 --force',status_input=status,proof_input=proof,exit_code=out.returncode,stdout=out.stdout,stderr=out.stderr,windows_before=before_windows,windows_after=after_windows,metadata_exists_after=meta.exists(),all_home_files_unchanged=unchanged,result='pass' if ok else 'fail'))
  print(json.dumps(records[-1]),flush=True)
 finally:
  t('kill-server')
evidence.write_text(json.dumps(dict(isolation='Disposable FM_HOME and HOME under the worktree; real tmux on per-case sockets; ps -u suppressed solely to prevent unrelated host orphan reaping. No product implementation is stubbed.',scenarios=records),indent=2)+'\n')
assert all(r['result']=='pass' for r in records)
