exec(open('.local-test/deliver.py').read().split('workerlog=')[0])
# Existing remote environment and endpoint, started only for this check.
workerlog=open(base/'worker-guards.log','w'); worker=s.Popen([str(root/'bin/fm-remote-job-worker.sh'),'--serve'],cwd=root,env=env,stdout=workerlog,stderr=workerlog)
for _ in range(100):
 if (base/'jobs/worker.ready').exists(): break
 time.sleep(.1)
script='''set -eu
. "$1/bin/fm-remote-job-lib.sh"
fm_remote_job_stage "$HOME" "$1" "$2" fm-remote-secondmate-control.sh send rsm "$3" </dev/null >/dev/null
fm_remote_job_wait "$HOME" "$FM_REMOTE_JOB_ID"
printf 'exit=%s\\n' "$FM_REMOTE_JOB_EXIT"
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
exit "$FM_REMOTE_JOB_EXIT"
'''
def send(home,message):
 p=s.run(['/usr/local/bin/bash','-c',script,'_',str(root),str(home),message],cwd=root,env=env,text=True,capture_output=True,timeout=60)
 assert p.returncode==0,(p.stdout,p.stderr)
 return p.stdout+p.stderr
try:
 # Re-send an already acknowledged request: no duplicate record or terminal input.
 request='Locale-free delivery 1: accents éà and multiline\nsecond line — durable body, not terminal text.'
 inbox=state/'rsm.inbox'; original=inbox/'001.msg'; saved=original.read_bytes(); original.rename(inbox/'handled/001.msg')
 n=len((base/'received.jsonl').read_text().splitlines()); out=send(home,request); time.sleep(1)
 assert 'already delivered and acknowledged' in out,out
 assert (inbox/'handled/001.msg').read_bytes()==saved and not original.exists()
 assert len(list(inbox.rglob('*.msg')))==10
 assert len((base/'received.jsonl').read_text().splitlines())==n
 log='ACKNOWLEDGED RETRY\n'+out+'receiver requests unchanged; exactly ten durable records remain\n'
 # Control byte in an otherwise genuine home must not be typed into the pane.
 hostile=base/'hostile-\x1b-home'; hs=hostile/'state/parent-route'; hs.mkdir(parents=True,exist_ok=True); (hostile/'bin').mkdir(exist_ok=True)
 (hostile/'AGENTS.md').write_bytes((home/'AGENTS.md').read_bytes()); (hostile/'.fm-secondmate-home').write_text('rsm\n'); (hs/'rsm.meta').write_bytes((state/'rsm.meta').read_bytes())
 out=send(hostile,'must remain durable without terminal control delivery'); time.sleep(1)
 assert 'doorbell did not reach' in out,out
 assert len(list((hs/'rsm.inbox').glob('*.msg')))==1
 assert len((base/'received.jsonl').read_text().splitlines())==n
 log+='\nHOSTILE PATH REJECTION\n'+out+'receiver requests unchanged; one durable message retained\n'
 (evidence/'delivery-guards.txt').write_text(log)
 print(log)
finally:
 worker.terminate(); worker.wait(timeout=15)
# Verify receiver-side contract from ten actual requests, not implementation source.
requests=[json.loads(l) for l in (base/'received.jsonl').read_text().splitlines()]
assert len(requests)==10
received=[]
for req in requests:
 msg=[m for m in req['messages'] if m['role']=='user'][-1]['content']
 if isinstance(msg,list): msg=''.join(b.get('text','') for b in msg)
 assert msg.startswith(': Firstmate instruction waiting:')
 assert 'Locale-free delivery' not in msg
 received.append(msg)
assert len(set(received))==1
(evidence/'receiver-doorbells.txt').write_text('Ten real Pi HTTP requests carried exactly this same doorbell; no steer bodies were typed into the terminal.\n\n'+received[0]+'\n')
# Preserve the actual terminal view as readable rendered HTML, not a simulated UI.
import html
screen=h('pane','read',pane,'--source','recent-unwrapped','--lines','300')
(evidence/'pane.html').write_text('<!doctype html><meta charset="utf-8"><title>Live remote doorbell delivery</title><body style="background:#151515;color:#eee"><h1>Live Herdr / Pi pane after ten remote-job sends</h1><p>The response endpoint is disposable; Firstmate, the queue worker, Herdr, and Pi are real.</p><pre style="white-space:pre-wrap">'+html.escape(screen)+'</pre>')
