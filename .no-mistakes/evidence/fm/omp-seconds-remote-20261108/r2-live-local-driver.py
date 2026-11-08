import os,subprocess,shutil,time,json
from pathlib import Path
r=Path.cwd(); w=r/'.validation'; code=w/'code'; home=w/'parent'; sm=w/'mate'; user=w/'user'; tools=w/'tools'; ev=Path('/Users/pierre/.no-mistakes/evidence/01M6WYC65Q7211TQMBX0B9X56D')
for p in [code,home,sm,user,tools]: p.mkdir(exist_ok=True)
shutil.copytree(r/'bin',code/'bin',dirs_exist_ok=True); shutil.copytree(r/'.omp',code/'.omp',dirs_exist_ok=True)
for p in [home/'config/secondmate-harness.d',home/'state',home/'data',sm/'data',sm/'bin']: p.mkdir(parents=True,exist_ok=True)
(sm/'AGENTS.md').write_text('Disposable launch validation. Do not run tools or change any files.\n'); (sm/'.fm-secondmate-home').write_text('mate\n'); (sm/'data/charter.md').write_text('Disposable validation only.\n')
(home/'config/secondmate-harness').write_text('opencode global-model low\n'); (home/'config/secondmate-harness.d/mate').write_text('omp openai-codex/gpt-6.1-sol medium\n')
sock=r/'.v.sock'; tmux=shutil.which('tmux'); wrapper=tools/'tmux'; wrapper.write_text(f'#!/bin/sh\nexec {tmux} -S "{sock}" -f /dev/null "$@"\n'); wrapper.chmod(0o755)
env={k:v for k,v in os.environ.items() if not any(s in k for s in ['API_KEY','TOKEN','SECRET']) and not k.startswith(('FM_','HERDR_','CLAUDE','PI_','OMP_','OPENCODE','GROK','CURSOR'))}
env.update(HOME=str(user),XDG_CONFIG_HOME=str(user/'config'),XDG_DATA_HOME=str(user/'data'),XDG_CACHE_HOME=str(user/'cache'),FM_HOME=str(home),FM_ROOT_OVERRIDE=str(code),FM_BACKEND='tmux',FM_GATE_REFUSE_BYPASS='1',TMUX='',PATH=str(tools)+':'+os.environ['PATH'])
log=[]
def run(args,timeout=100):
 p=subprocess.run(args,env=env,capture_output=True,text=True,timeout=timeout); log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+f'\nexit={p.returncode}\n'); return p
try:
 if not (sm/'.git').exists():
  for args in [['git','-C',str(sm),'init','-q'],['git','-C',str(sm),'config','user.email','test@example.invalid'],['git','-C',str(sm),'config','user.name','Disposable Validation'],['git','-C',str(sm),'add','.'],['git','-C',str(sm),'commit','-qm','Disposable secondmate seed']]: run(args)
 run([str(wrapper),'new-session','-d','-s','firstmate','-x','140','-y','40'])
 p=run([str(r/'bin/fm-spawn.sh'),'mate',str(sm),'--secondmate'])
 if (home/'state/mate.meta').exists(): log.append('Persisted parent endpoint record:\n'+(home/'state/mate.meta').read_text())
 time.sleep(25)
 run([str(wrapper),'send-keys','-t','firstmate:fm-mate','C-u'])
 time.sleep(2)
 before=run([str(wrapper),'capture-pane','-p','-e','-t','firstmate:fm-mate','-S','-100'])
 (ev/'r2-omp-before-relaunch-ansi.txt').write_text(before.stdout)
 (home/'config/secondmate-harness.d/mate').write_text('omp openai-codex/gpt-6.1-sol high\n')
 p=run([str(r/'bin/fm-control.sh'),'mate','relaunch'],timeout=140)
 if (home/'state/mate.meta').exists(): log.append('Endpoint record after configured-effort relaunch:\n'+(home/'state/mate.meta').read_text())
 time.sleep(15)
 p=run([str(wrapper),'capture-pane','-p','-t','firstmate:fm-mate','-S','-100']); (ev/'r2-local-omp-terminal.txt').write_text(p.stdout)
 log.append(run([str(wrapper),'display-message','-p','-t','firstmate:fm-mate','#{pane_current_command} #{pane_width}x#{pane_height}']).stdout)
finally:
 run([str(wrapper),'kill-server']); (ev/'r2-local-omp-launch.txt').write_text('\n'.join(log)); print('\n'.join(log))
