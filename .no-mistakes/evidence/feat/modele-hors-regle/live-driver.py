import os, pathlib, subprocess, json, time, shutil
R=pathlib.Path.cwd(); D=R/'.local-test/live'; E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M69WQ4V9X7K9W2YX5N8G02B5'); D.mkdir(parents=True,exist_ok=True)
B=D/'bin'; B.mkdir(exist_ok=True)
(B/'bash').write_text('#!/bin/sh\nexec /bin/bash "$@"\n'); (B/'bash').chmod(0o755)
SOCKET='fm-local-validation-'+str(os.getpid())
(B/'tmux').write_text('#!/bin/sh\n/usr/local/bin/tmux -L '+SOCKET+' "$@" 2>>"'+str(D/'tmux-errors.log')+'"\nc=$?\nprintf "status=%s args=%s\\n" "$c" "$*" >>"'+str(D/'tmux-errors.log')+'"\nexit "$c"\n'); (B/'tmux').chmod(0o755)
env={'PATH':str(B)+':'+os.environ['PATH'],'HOME':str(D/'user'),'TMPDIR':str(R/'.local-test/tmp'),'SHELL':'/bin/bash','TERM':'xterm-256color','FM_HOME':str(D/'home'),'FM_SPAWN_NO_GUARD':'1','FM_GATE_REFUSE_BYPASS':'1','CLAUDE_CONFIG_DIR':str(D/'user'),'GROK_HOME':str(D/'grok'),'FM_CONTROL_LAUNCH_WAIT':'15','FM_CONTROL_EXIT_WAIT':'5'}
for p in ['user','home/state','home/data','home/config']: (D/p).mkdir(parents=True,exist_ok=True)
log=[]; results=[]
def run(args,check=True):
 p=subprocess.run([str(x) for x in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
 log.append('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+'[exit '+str(p.returncode)+']\n')
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p

def setup(id,kind='ship',harness='claude',model='default',effort='default',reason='old deliberate choice'):
 proj=D/'project'; wt=D/('wt-'+id)
 if not proj.exists():
  proj.mkdir(); run(['git','-C',proj,'init','-q']); run(['git','-C',proj,'-c','user.name=Local Tester','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','fixture'])
 run(['git','-C',proj,'worktree','add','-qb',id,wt])
 run(['tmux','new-window','-d','-t','validation:','-n','fm-'+id,'-c',wt,'/bin/bash --noprofile --norc']); time.sleep(0.1)
 run(['tmux','list-windows','-t','validation','-F','#{window_name}'])
 brief=D/'home/data'/id/'brief.md'; brief.parent.mkdir(parents=True); brief.write_text('# Task\n\n## Captain\'s intent\nDo not perform any work or network requests. Wait for instructions.\n\n## Firstmate spec\nLocal validation only.\n')
 meta=D/'home/state'/(id+'.meta')
 fields={'window':'validation:fm-'+id,'endpoint_task_id':id,'worktree':str(wt),'project':str(proj),'harness':harness,'kind':kind,'mode':'no-mistakes' if kind=='ship' else '', 'yolo':'off' if kind=='ship' else '', 'tasktmp':str(D/('tasktmp-'+id)),'model':model,'effort':effort,'dispatch_override_reason':reason}
 meta.write_text(''.join(k+'='+v+'\n' for k,v in fields.items() if v))
 return meta

def scenario(name,id,flags,kind='ship',model='default',effort='default',expect=0,control=False,want_reason=None):
 meta=setup(id,kind,model=model,effort=effort); before=meta.read_bytes()
 args=[R/'bin'/('fm-control.sh' if control else 'fm-spawn.sh'),id]
 args+=['relaunch','--note','Disposable validation replacement'] if control else ['--relaunch','--harness','claude']
 p=run(args+flags,False); after=meta.read_text(); log.append('PERSISTED TASK RECORD '+id+'\n'+after)
 ok=p.returncode==expect
 if expect:
  ok=ok and meta.read_bytes()==before and ('matches no profile' in p.stdout or 'single line' in p.stdout or 'non-empty reason' in p.stdout or 'at most 500' in p.stdout or 'applies only' in p.stdout)
 else:
  reasons=[x.partition('=')[2] for x in after.splitlines() if x.startswith('dispatch_override_reason=')]
  ok=ok and reasons==([] if want_reason is None else [want_reason])
  status=D/'home/state'/(id+'.status')
  if status.exists(): log.append('STATUS '+id+'\n'+status.read_text())
 results.append({'name':name,'pass':ok,'exit':p.returncode});
 if not ok: print('FAILED',name,p.stdout,flush=True)
 else: print('PASS',name,flush=True)
try:
 run(['tmux','-f','/dev/null','new-session','-d','-s','validation','-x','120','-y','40','/bin/bash --noprofile --norc'])
 (D/'home/config/crew-dispatch.json').write_text(json.dumps({'rules':[{'when':'model selection','use':[{'harness':'claude','model':'sonnet','effort':'high'},{'harness':'codex','model':'gpt-5','effort':'high'}]}],'default':{'harness':'claude'}}))
 scenario('Worker off-profile relaunch refuses and preserves old record','lv01',['--model','haiku','--effort','low'],model='haiku',effort='low',expect=1)
 scenario('Scout off-profile relaunch refuses and preserves old record','lv02',['--model','haiku'],kind='scout',model='haiku',expect=1)
 scenario('Unchanged declared triplet preserves recorded reason','lv03',[],want_reason='old deliberate choice')
 scenario('Changed effort removes old reason','lv04',['--effort','high'])
 scenario('Changed declared model removes old reason','lv05',['--model','sonnet','--effort','high'])
 scenario('Control forwards new override and replaces old reason','lv06',['--model','haiku','--effort','low','--override-reason','Deliberate low-cost replacement'],control=True,want_reason='Deliberate low-cost replacement')
 scenario('Scout accepts explicit override on relaunch','lv07',['--model','haiku','--override-reason','Deliberate scout choice'],kind='scout',want_reason='Deliberate scout choice')
 scenario('Newline reason cannot inject metadata','lv08',['--override-reason','bad\nmodel=injected'],expect=1)
 scenario('Whitespace-only reason refuses','lv09',['--override-reason','   '],expect=1)
 scenario('Overlong reason refuses','lv10',['--override-reason','x'*501],expect=1)
 scenario('Secondmate relaunch rejects override flag','lv11',['--override-reason','not applicable'],kind='secondmate',expect=1)
 # Fresh dispatch must reject before creating an endpoint or publishing a record.
 for id,kind in [('freshship','ship'),('freshscout','scout')]:
  brief=D/'home/data'/id/'brief.md'; brief.parent.mkdir(parents=True); brief.write_text('# Task\n## Captain\'s intent\nDisposable launch validation.\n\n## Firstmate spec\nDo not perform work.\n')
  args=[R/'bin/fm-spawn.sh',id,D/'project','--harness','claude','--model','haiku']+(['--scout'] if kind=='scout' else ['--mode','no-mistakes','--yolo','off'])
  before=run(['tmux','list-windows','-a','-F','#{session_name}:#{window_name}']).stdout
  p=run(args,False)
  after=run(['tmux','list-windows','-a','-F','#{session_name}:#{window_name}']).stdout
  results.append({'name':kind+' fresh off-profile launch refuses before creating endpoint or record','pass':p.returncode==1 and 'matches no profile' in p.stdout and not (D/'home/state'/(id+'.meta')).exists() and before==after,'exit':p.returncode})
 # No dispatch config: the reason still belongs only to the exact original triplet.
 (D/'home/config/crew-dispatch.json').unlink()
 scenario('Unchanged triplet without dispatch config retains reason','lv12',[],want_reason='old deliberate choice')
 scenario('Model change without dispatch config drops reason','lv13',['--model','sonnet'])
 # Harness change, using the actual installed codex runtime and real tmux pane.
 meta=setup('lv14'); p=run([R/'bin/fm-spawn.sh','lv14','--relaunch','--harness','codex'],False)
 after=meta.read_text(); log.append('PERSISTED TASK RECORD lv14\n'+after)
 results.append({'name':'Harness change removes old reason','pass':p.returncode==0 and 'dispatch_override_reason=' not in after,'exit':p.returncode})
 time.sleep(2)
 run(['tmux','capture-pane','-p','-t','validation:fm-lv06'])
except Exception as e:
 log.append('DRIVER ERROR '+repr(e)); results.append({'name':'driver completion','pass':False,'error':repr(e)})
finally:
 run(['tmux','kill-server'],False)
 (E/'live-dispatch-transcript.log').write_text('\n'.join(log)); (E/'live-results.json').write_text(json.dumps(results,indent=2))
 print(json.dumps(results,indent=2))
