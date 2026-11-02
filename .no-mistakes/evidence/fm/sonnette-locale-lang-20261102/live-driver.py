import os, pathlib, subprocess, json, time, shutil, base64
R=pathlib.Path.cwd(); L=R/'.validation/live'; E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6ENRYXSZ0VQ0J83QKX43XZX')
L.mkdir(); A=L/'account'; H=L/'home'; S=L/'jobs'; B=A/'.local/bin'; B.mkdir(parents=True); (H/'state').mkdir(parents=True)
T=shutil.which('tmux'); SH=shutil.which('bash'); sock=str(L/'tmux.sock'); log=[]
def run(args, env=None, check=True):
 p=subprocess.run(args,env=env,text=True,capture_output=True); log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 if check and p.returncode: raise RuntimeError(log[-1])
 return p
(B/'tmux').write_text('#!/bin/sh\nexec '+T+' -S '+sock+' "$@"\n'); (B/'tmux').chmod(0o755)
# Instrument executable resolution, not the product: log the actual sanitized
# environment handed to env-bash commands and then exec the installed Bash.
(B/'bash').write_text('#!/bin/sh\nprintf "LANG=%s LC_ALL=%s secret=%s HOME=%s command=%s\\n" "${LANG-unset}" "${LC_ALL-unset}" "${LOCALE_TEST_SECRET-unset}" "$HOME" "$1" >> '+str(L/'child-env.log')+'\nexport FM_GATE_REFUSE_BYPASS=1\nexec '+SH+' "$@"\n'); (B/'bash').chmod(0o755)
env={'PATH':str(B)+':'+os.environ['PATH'],'HOME':str(A),'FM_HOME':str(H),'FM_ROOT_OVERRIDE':str(R),'FM_REMOTE_JOB_STATE_ROOT':str(S),'TMPDIR':str(R/'.validation/tmp'),'FM_REMOTE_JOB_PLATFORM_OVERRIDE':'Linux','LOCALE_TEST_SECRET':'must-not-leak'}
run([T,'-S',sock,'-f','/dev/null','new-session','-d','-s','locale','-n','fm-locale','-x','240','-y','35','/bin/sh','-c','stty -echo; exec /bin/cat' ],env)
(H/'state/locale.meta').write_text('backend=tmux\nwindow=locale:fm-locale\nkind=ship\nharness=pi\n')
workerlog=open(L/'worker.log','w'); worker=subprocess.Popen([str(R/'bin/fm-remote-job-worker.sh'),'--serve'],env=env,stdout=workerlog,stderr=workerlog,cwd=R)
try:
 for i in range(100):
  if (S/'worker.pid').exists(): break
  time.sleep(.1)
 for n in range(1,11):
  script='''set -eu
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$HOME" "$1" "$FM_HOME" fm-send.sh locale "$2" </dev/null >/dev/null
id=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$HOME" "$id"
printf 'job=%s exit=%s\\n' "$id" "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
exit "$FM_REMOTE_JOB_EXIT"
'''
  p=run([SH,'-c',script,'_',str(R),f'Isolated locale steer {n:02d}'],env)
  assert 'doorbell did not reach' not in p.stderr and 'doorbell not typed' not in p.stderr and 'doorbell skipped' not in p.stderr
  time.sleep(.1)
 recs=sorted((H/'state/locale.inbox').glob('*.msg')); assert len(recs)==10
 for i,p in enumerate(recs,1): assert f'Isolated locale steer {i:02d}' in p.read_text()
 screen=run([T,'-S',sock,'capture-pane','-p','-S','-200','-t','locale:fm-locale'],env).stdout
 assert screen.count(': Firstmate instruction waiting:')==10,screen
 (E/'remote-pane.txt').write_text(screen)
 (E/'inbox-records.txt').write_text('\n'.join(p.name+'\n'+p.read_text() for p in recs))
 child=(L/'child-env.log').read_text(); assert 'LANG=C LC_ALL=unset secret=unset' in child
 (E/'worker-child-environment.txt').write_text(child)
 # Exercise the public producer with truly absent locale, both shells, and
 # shell-hostile printable paths; a terminal control path must be refused.
 d=L/"inbox ' ; touch SHOULD_NOT_EXIST ; '"; d.mkdir()
 for shell in ['/bin/bash',SH]:
  p=run([shell,'-c','. "$1/bin/fm-task-inbox-lib.sh"; line=$(fm_task_inbox_doorbell_line "$2/001.msg") || exit; printf "%s\\n" "$line"; /bin/sh -c "$line"','_',str(R),str(d)],{'PATH':os.environ['PATH'],'HOME':str(A)})
  assert not (R/'SHOULD_NOT_EXIST').exists()
  bad=L/'unsafe\npath'; bad.mkdir(exist_ok=True)
  p=run([shell,'-c','. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2/001.msg"','_',str(R),str(bad)],{'PATH':os.environ['PATH'],'HOME':str(A)},False)
  assert p.returncode==1 and p.stdout==''
 # Redirect only the bootstrap account-home lookup to the disposable account.
 # The tracked entrypoint and doctor remain unmodified; --help is inert.
 enc=lambda s:base64.b64encode(s.encode()).decode()
 C=L/'code'; C.mkdir(); shutil.copytree(R/'bin',C/'bin'); shutil.copyfile(R/'AGENTS.md',C/'AGENTS.md')
 genv=env|{'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}
 run(['git','-C',str(C),'init','-q'],genv); run(['git','-C',str(C),'add','bin'],genv)
 entry='''cd() { if [ "$#" = 1 ] && [ "$1" = "$REAL_ACCOUNT" ]; then builtin cd "$TEST_ACCOUNT"; else builtin cd "$@"; fi; }
set -- 1 "$2" "$3" "$4"
. "$ENTRY"
'''
 denv=env|{'REAL_ACCOUNT':os.path.expanduser('~'),'TEST_ACCOUNT':str(A),'ENTRY':str(R/'bin/fm-remote-entrypoint.sh')}
 p=run([SH,'-c',entry,'_', 'unused',enc(str(C)),enc(str(H)),enc('fm-remote-doctor.sh\0--help\0')],denv)
 assert 'remote' in p.stdout.lower()
 child=(L/'child-env.log').read_text(); assert 'LANG=C LC_ALL=unset secret=unset HOME='+str(A)+' command='+str(C/'bin/fm-remote-doctor.sh') in child
 (E/'worker-child-environment.txt').write_text(child)
 (E/'doctor-bootstrap-help.txt').write_text(p.stdout)
finally:
 worker.terminate()
 try: worker.wait(timeout=15)
 except subprocess.TimeoutExpired: worker.kill(); worker.wait()
 run([T,'-S',sock,'kill-server'],env,False)
 workerlog.close()
 (E/'live-transcript.json').write_text(json.dumps(log,indent=2))
 (E/'live-driver.py').write_text(pathlib.Path(__file__).read_text())
print('Live validation completed: ten worker steers reached the private pane; ten durable records; sanitized LANG=C; hostile paths safe; doctor bootstrap executed.')
