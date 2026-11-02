exec(open('.local-test/live.py').read().split('serverlog=')[0])
# Reuse only the disposable server created in this run.
pane=(base/'pane').read_text()
def h(*args): return cmd(['herdr',*args,'--session','fm-lab-locale'])
time.sleep(1)
(evidence/'pi-before.txt').write_text(h('pane','read',pane,'--source','recent','--lines','100'))
# Adapt only the endpoint namespace, not product behavior: remote control's
# fixed fm-remote namespace goes to our isolated fm-lab-locale server.
wrapper=account/'.local/bin/herdr'
wrapper.write_text('#!/usr/local/bin/bash\nset -eu\ncd '+shlex.quote(str(root))+'\nexport HOME='+shlex.quote(str(account))+' XDG_CONFIG_HOME=.local-test/c HERDR_CONFIG_PATH=.local-test/c/config.toml\nargs=("$@")\nn=${#args[@]}\nif [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then\n [ "${args[$((n-1))]}" = fm-remote ] || exit 98\n args=("${args[@]:0:$((n-2))}")\nfi\nexport PATH='+shlex.quote(os.environ['PATH'])+'\nexec '+shlex.quote(str(root/'bin/fm-herdr-lab.sh'))+' run fm-lab-locale "${args[@]}"\n')
wrapper.chmod(0o755)
if not (account/'.local/bin/jq').exists(): (account/'.local/bin/jq').symlink_to('/Users/pierre/.local/bin/jq')
home=base/'secondmate'; state=home/'state/parent-route'; state.mkdir(parents=True,exist_ok=True); (home/'bin').mkdir(exist_ok=True)
(home/'.fm-secondmate-home').write_text('rsm\n'); (home/'AGENTS.md').write_bytes((root/'AGENTS.md').read_bytes())
(state/'rsm.meta').write_text(f'window=fm-remote:{pane}\nworktree=-\nproject=-\nbackend=herdr\nendpoint_task_id=rsm\nharness=pi\nherdr_session=fm-remote\nherdr_workspace_id={pane.split(':')[0]}\nherdr_tab_id={pane.split(':')[0]}:t1\nherdr_pane_id={pane}\n')
env.update(FM_ROOT_OVERRIDE=str(root),FM_REMOTE_JOB_STATE_ROOT=str(base/'jobs'),FM_REMOTE_JOB_TIMEOUT='45',FM_REMOTE_JOB_QUEUE_TIMEOUT='45')
workerlog=open(base/'worker.log','w'); worker=s.Popen([str(root/'bin/fm-remote-job-worker.sh'),'--serve'],cwd=root,env=env,stdout=workerlog,stderr=workerlog)
(base/'worker-pid').write_text(str(worker.pid))
for _ in range(100):
 if (base/'jobs/worker.ready').exists(): break
 if worker.poll() is not None: raise RuntimeError((base/'worker.log').read_text())
 time.sleep(.1)
else: raise RuntimeError('worker not ready')
script='''set -eu
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$HOME" "$1" "$2" fm-remote-secondmate-control.sh send rsm "$3" </dev/null >/dev/null
id=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$HOME" "$id"
printf 'job=%s exit=%s\\n' "$id" "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
exit "$FM_REMOTE_JOB_EXIT"
'''
log=[]
try:
 for i in range(1,11):
  message=f'Locale-free delivery {i}: accents éà and multiline\nsecond line — durable body, not terminal text.'
  out=cmd(['/usr/local/bin/bash','-c',script,'_',str(root),str(home),message],timeout=70)
  log.append(out); print(out,flush=True)
  time.sleep(.2)
 (evidence/'remote-delivery-jobs.txt').write_text(''.join(log))
 screen=h('pane','read',pane,'--source','recent-unwrapped','--lines','300'); (evidence/'pi-after.txt').write_text(screen); print(screen,flush=True)
 records=sorted((state/'rsm.inbox').glob('*.msg')); assert len(records)==10,records
 (evidence/'persisted-steers.txt').write_text('\n'.join(p.name+'\n'+p.read_text() for p in records))
 assert 'Firstmate instruction waiting' in screen, 'doorbell not observed in real pane'
 assert 'doorbell did not reach' not in ''.join(log)
finally:
 worker.terminate(); worker.wait(timeout=15)
