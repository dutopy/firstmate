import os, pathlib, subprocess, json, time, threading, http.server, html, shutil
ROOT=pathlib.Path.cwd(); LAB=ROOT/'.test-lab'; EV=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M69W5BQMS7DGVNE9SPTB6270')
LAB.mkdir(exist_ok=True);(LAB/'tmp').mkdir(exist_ok=True)
TMUX=shutil.which('tmux'); PI=shutil.which('pi'); SOCK=str(LAB/'terminal.sock')
requests=[]; release=threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  requests.append(data); (EV/'local-endpoint-requests.json').write_text(json.dumps(requests,indent=2))
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
  def event(delta,finish=None):
   chunk={'id':'local-check','object':'chat.completion.chunk','created':int(time.time()),'model':'local-check','choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
   self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode()); self.wfile.flush()
  try:
   event({'role':'assistant','content':'Local validation response in progress. '})
   if len(requests)>1: release.wait(100)
   event({'content':'Complete.'}); event({},'stop'); self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler); threading.Thread(target=server.serve_forever,daemon=True).start()
agent=LAB/'agent'; agent.mkdir(exist_ok=True)
(agent/'models.json').write_text(json.dumps({'providers':{'validation':{'baseUrl':f'http://127.0.0.1:{server.server_port}/v1','api':'openai-completions','apiKey':'disposable','models':[{'id':'local-check','contextWindow':32000,'maxTokens':1000}]}}}))
shim=LAB/'shim'; shim.mkdir(exist_ok=True)
(shim/'tmux').write_text('#!/usr/bin/env python3\nimport subprocess,sys,json\nwith open('+repr(str(EV/'tmux-commands.jsonl'))+',"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nsys.exit(subprocess.call(['+repr(TMUX)+',"-S",'+repr(SOCK)+']+sys.argv[1:]))\n'); (shim/'tmux').chmod(0o755)
home=LAB/'home'; (home/'state').mkdir(parents=True,exist_ok=True)
env={'PATH':str(shim)+':'+os.environ['PATH'],'HOME':str(home),'TMPDIR':str(LAB/'tmp'),'PI_CODING_AGENT_DIR':str(agent),'TERM':'xterm-256color','FM_HOME':str(home),'FM_ROOT_OVERRIDE':str(home),'FM_STATE_OVERRIDE':str(home/'state'),'FM_GATE_REFUSE_BYPASS':'1','FM_TASK_INBOX_ENTER_PAUSE':'1','FM_TASK_INBOX_GRACE_SECS':'1','FM_POLL':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_HOME_SUMMARY_INTERVAL':'999999','FM_SIGNAL_GRACE':'1','FM_BUSY_REGEX':'Working'}
def tm(*args): return subprocess.check_output([TMUX,'-S',SOCK,*args],env=env,text=True)
def shell(code,check=True):
 p=subprocess.run(['/bin/bash','-c',code],env=env,cwd=ROOT,text=True,capture_output=True)
 with (EV/'live-transcript.log').open('a') as f: f.write('$ '+code+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
 if check and p.returncode: raise RuntimeError(p.stderr+ p.stdout)
 return p
observations=[]; watchers=[]
def obs(name,**kw): observations.append({'name':name,**kw}); (EV/'live-observations.json').write_text(json.dumps(observations,indent=2))
def lib(code,check=True): return shell('. bin/fm-task-inbox-lib.sh; '+code,check)
def state(fn): return lib(fn+' tmux lab:worker').stdout.strip()
def capture(name):
 text=tm('capture-pane','-p','-t','lab:worker','-S','-100')
 (EV/(name+'.txt')).write_text(text)
 (EV/(name+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>Live terminal capture</title><body style="background:#111;color:#ddd"><pre>'+html.escape(text)+'</pre>')
 return text
def commands(): return [json.loads(x) for x in (EV/'tmux-commands.jsonl').read_text().splitlines()]
def enter_count(start): return sum(c[0]=='send-keys' and c[-1]=='Enter' for c in commands()[start:])
def watch(name,successor=False):
 e=env.copy()
 if successor:e['FM_WATCH_HANDLING_SUCCESSOR']='1'
 out=(EV/(name+'.log')).open('w'); p=subprocess.Popen(['/bin/bash','bin/fm-watch.sh'],env=e,cwd=ROOT,stdout=out,stderr=subprocess.STDOUT); watchers.append((p,out));return p
try:
 tm('new-session','-d','-s','lab','-n','worker','-x','220','-y','50','-c',str(LAB),'env','-i',*[k+'='+v for k,v in env.items()],PI,'--offline','--no-session','--no-extensions','--no-skills','--no-prompt-templates','--no-themes','--no-context-files','--no-approve','--no-tools','--provider','validation','--model','local-check','--tui-mode','regular')
 tm('set-option','-g','automatic-rename','off'); tm('rename-window','-t','lab:0','worker'); tm('new-window','-d','-t','lab:','-n','keeper','-c',str(LAB),'/bin/bash','--noprofile','--norc')
 for _ in range(30):
  if state('fm_backend_composer_state')=='empty':break
  time.sleep(1)
 else: capture('startup-blocked');raise RuntimeError('Pi composer not ready')
 (home/'state'/'t1.meta').write_text('window=lab:worker\nkind=secondmate\nharness=pi\nbackend=tmux\n')
 rec=lib('fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 "disposable validation message"').stdout.strip()
 # Pending user draft must be protected, through the public fm-send path.
 tm('send-keys','-t','lab:worker','-l','DO NOT SUBMIT THIS DRAFT'); time.sleep(.5)
 capture('draft-before-send'); print('draft state',state('fm_backend_composer_state'),flush=True)
 before=len(commands()); p=shell('/bin/bash bin/fm-send.sh t1 "new steer while user is drafting"')
 assert 'composer visibly holds pending text' in p.stderr and enter_count(before)==0
 assert 'DO NOT SUBMIT THIS DRAFT' in capture('pending-draft-protected')
 obs('Existing pending draft is not submitted',result='pass',enters=0)
 tm('send-keys','-t','lab:worker','C-u');time.sleep(.2)
 # A real turn starts against the disposable endpoint and receives the doorbell exactly once.
 before=len(commands());p=lib('fm_task_inbox_ring tmux lab:worker '+repr(rec))
 time.sleep(1); busy=state('fm_backend_busy_state'); screen=capture('doorbell-submitted')
 obs('Empty submit verdict needs no confirming Enter',result='pass' if enter_count(before)==1 else 'fail',enters=enter_count(before),busy=busy,requests=len(requests))
 assert enter_count(before)==1 and requests
 # Start a long real Pi turn against the held local endpoint, then steer while busy.
 tm('send-keys','-t','lab:worker','-l','Hold this disposable turn open');tm('send-keys','-t','lab:worker','Enter');time.sleep(1)
 before=len(commands());p=lib('fm_task_inbox_ring tmux lab:worker '+repr(rec));time.sleep(.3)
 busy2=lib('. bin/fm-tmux-lib.sh; fm_pane_busy_state lab:worker').stdout;capture('busy-doorbell-queued')
 obs('Busy worker accepts a doorbell into its queue',result='pass',enters=enter_count(before),busy=busy2)
 assert busy2=='busy'
 # Adversarial real Pi keymap: Enter moves right rather than submits, so its composer retains the doorbell.
 tm('rename-window','-t','lab:worker','saved')
 (agent/'keybindings.json').write_text(json.dumps({'tui.input.submit':'ctrl+s','tui.editor.cursorRight':['right','enter']}))
 tm('new-window','-d','-t','lab:','-n','worker','-c',str(LAB),'env','-i',*[k+'='+v for k,v in env.items()],PI,'--offline','--no-session','--no-extensions','--no-skills','--no-prompt-templates','--no-themes','--no-context-files','--no-approve','--no-tools','--provider','validation','--model','local-check','--tui-mode','regular')
 for _ in range(30):
  if state('fm_backend_composer_state')=='empty':break
  time.sleep(1)
 # Exercise the backend's proven-pending + busy queued conversion using the supported busy-regex override.
 old_regex=env['FM_BUSY_REGEX'];env['FM_BUSY_REGEX']='local-check'
 before=len(commands());p=lib('fm_task_inbox_ring tmux lab:worker '+repr(rec),False)
 obs('Busy-queued empty submit verdict stops after one Enter',result='pass' if p.returncode==0 and enter_count(before)==1 else 'fail',returncode=p.returncode,enters=enter_count(before),busy=lib('. bin/fm-tmux-lib.sh; fm_pane_busy_state lab:worker').stdout)
 assert p.returncode==0 and enter_count(before)==1
 capture('busy-empty-verdict');tm('send-keys','-t','lab:worker','C-u');time.sleep(.5);env['FM_BUSY_REGEX']=old_regex
 before=len(commands()); p=lib('fm_task_inbox_ring tmux lab:worker '+repr(rec),False)
 capture('busy-stuck-doorbell')
 obs('Pending composer retains one doorbell until bounded confirmation retries finish',result='pass' if p.returncode==4 and enter_count(before)==6 else 'fail',returncode=p.returncode,enters=enter_count(before),composer=state('fm_backend_composer_state'),busy=lib('. bin/fm-tmux-lib.sh; fm_pane_busy_state lab:worker').stdout)
 assert p.returncode==4 and enter_count(before)==6
 # Urgent tier must remain independent of an already-escalated idle tier on a live busy endpoint.
 tm('kill-window','-t','lab:worker');tm('rename-window','-t','lab:saved','worker')
 os.utime(rec,(1577836800,1577836800));lib('fm_task_inbox_record_escalated "$FM_STATE_OVERRIDE" t1 '+repr(rec))
 shell('wc -c "$FM_STATE_OVERRIDE"/*.status 2>/dev/null | cksum > "$FM_STATE_OVERRIDE/.antidrift-sig"; printf "%s\\n" "$(( $(date +%s) + 10000 ))" > "$FM_STATE_OVERRIDE/.antidrift-next"; touch "$FM_STATE_OVERRIDE/home-summary.json"')
 env['FM_TASK_INBOX_URGENT_SECS']='1';env['FM_TASK_INBOX_URGENT_MAX']='1'
 before=len(commands());urgent=watch('urgent-after-idle-escalation');urgent.wait(timeout=30)
 q=(home/'state'/'.wake-queue').read_text();(EV/'urgent-after-idle-wake-queue.txt').write_text(q)
 assert 'unread-urgent' in q and enter_count(before)>0
 obs('Busy live worker gets urgent delivery and notification after idle-tier escalation',result='pass',queue=q,enters=enter_count(before))
 env.pop('FM_TASK_INBOX_URGENT_SECS');env.pop('FM_TASK_INBOX_URGENT_MAX')
 # The next cases start fresh notification state but keep real attempt bookkeeping.
 for f in (home/'state').glob('.wake-*'):
  if f.is_file():f.unlink()
 # Real terminal endpoint dies back to an interactive shell; stale previous-message ladder survives.
 tm('kill-window','-t','lab:worker');tm('new-window','-d','-t','lab:','-n','worker','-c',str(LAB),'bash','--noprofile','--norc');time.sleep(.5)
 lib('fm_task_inbox_record_ring "$FM_STATE_OVERRIDE" t1 '+repr(rec))
 inbox=home/'state'/'t1.inbox';(inbox/'handled').mkdir(exist_ok=True)
 for msg in inbox.glob('*.msg'):msg.rename(inbox/'handled'/msg.name)
 rec=lib('fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 "worker exited before reading this instruction"').stdout.strip();os.utime(rec,(1577836800,1577836800))
 shell('wc -c "$FM_STATE_OVERRIDE"/*.status 2>/dev/null | cksum > "$FM_STATE_OVERRIDE/.antidrift-sig"; printf "%s\\n" "$(( $(date +%s) + 10000 ))" > "$FM_STATE_OVERRIDE/.antidrift-next"; touch "$FM_STATE_OVERRIDE/home-summary.json"')
 before=len(commands());p=watch('dead-pane-first-watcher',True);p.wait(timeout=30)
 queue=(home/'state'/'.wake-queue').read_text(); (EV/'dead-pane-wake-queue.txt').write_text(queue)
 assert 'agent has exited' in queue and '003.msg' in queue
 assert (inbox/'.escalated').read_text().strip()=='003.msg' and (inbox/'.urgent-escalated').read_text().strip()=='003.msg'
 assert lib('fm_task_inbox_due_action "$FM_STATE_OVERRIDE" t1').stdout=='quiet'
 p2=watch('dead-pane-successor',True);time.sleep(5)
 assert p2.poll() is None and (home/'state'/'.wake-queue').read_text()==queue
 assert enter_count(before)==0
 obs('Dead shell produces one notification despite stale previous-message attempts',result='pass',queue=queue,successor_alive=True,enters=0,markers={f:(inbox/f).read_text() for f in ['.ring-state','.escalated','.urgent-escalated']})
 p2.terminate();p2.wait(timeout=10)
 # Missing endpoint follows the same once-only escalation route for a new instruction.
 tm('kill-window','-t','lab:worker')
 pathlib.Path(rec).rename(inbox/'handled'/pathlib.Path(rec).name)
 rec=lib('fm_task_inbox_write "$FM_STATE_OVERRIDE" t1 "worker endpoint was removed"').stdout.strip();os.utime(rec,(1577836800,1577836800))
 p3=watch('missing-pane-watcher',True);p3.wait(timeout=30)
 queue2=(home/'state'/'.wake-queue').read_text();(EV/'missing-pane-wake-queue.txt').write_text(queue2)
 assert '004.msg' in queue2 and lib('fm_task_inbox_due_action "$FM_STATE_OVERRIDE" t1').stdout=='quiet'
 obs('Removed endpoint escalates new message once',result='pass',queue=queue2)
finally:
 release.set();server.shutdown()
 for p,f in watchers:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
  f.close()
 subprocess.run([TMUX,'-S',SOCK,'kill-server'],env=env,capture_output=True)
