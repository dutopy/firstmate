import os,subprocess,time
from pathlib import Path
r=Path.cwd(); w=r/'.validation'; home=w/'override-parent'; cfg=home/'config/secondmate-harness.d'; cfg.mkdir(parents=True,exist_ok=True); (home/'state').mkdir(exist_ok=True); (home/'data').mkdir(exist_ok=True)
user=w/'override-user'; user.mkdir(exist_ok=True); tools=w/'tools'; wrapper=tools/'tmux'
env={k:v for k,v in os.environ.items() if not any(s in k for s in ['API_KEY','TOKEN','SECRET']) and not k.startswith(('FM_','HERDR_','CLAUDE','PI_','OMP_','OPENCODE','GROK','CURSOR'))}
env.update(HOME=str(user),XDG_CONFIG_HOME=str(user/'config'),XDG_DATA_HOME=str(user/'data'),XDG_CACHE_HOME=str(user/'cache'),FM_HOME=str(home),FM_ROOT_OVERRIDE=str(w/'code'),FM_BACKEND='tmux',FM_GATE_REFUSE_BYPASS='1',TMUX='',PATH=str(tools)+':'+os.environ['PATH'])
logs=[]
def run(args):
 p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=100);logs.append('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}\n');return p
try:
 run([str(wrapper),'new-session','-d','-s','firstmate','-x','140','-y','40'])
 for id,profile,args,expected in [('nm-axes','omp deliberate-invalid-model high\n',['--model','openai-codex/gpt-6.1-sol','--effort','low'],{'harness':'omp','model':'openai-codex/gpt-6.1-sol','effort':'low'}),('nm-reset','opencode deliberate-invalid-model high\n',['--harness','omp'],{'harness':'omp','model':'default','effort':'default'})]:
  sm=w/id; (sm/'bin').mkdir(parents=True,exist_ok=True); (sm/'data').mkdir(exist_ok=True); (sm/'AGENTS.md').write_text('Disposable launch validation. Do not use tools.\n'); (sm/'.fm-secondmate-home').write_text(id+'\n');(sm/'data/charter.md').write_text('Validation only.\n');(cfg/id).write_text(profile)
  p=run([str(r/'bin/fm-spawn.sh'),id,str(sm),'--secondmate']+args);assert p.returncode==0
  meta=(home/'state'/f'{id}.meta').read_text(); logs.append('Persisted endpoint record:\n'+meta); fields=dict(line.split('=',1) for line in meta.splitlines() if '=' in line)
  for key,val in expected.items():assert fields.get(key)==val,(id,key,fields.get(key),val)
  time.sleep(20); run([str(wrapper),'capture-pane','-p','-t',f'firstmate:fm-{id}','-S','-60']);run([str(wrapper),'display-message','-p','-t',f'firstmate:fm-{id}','#{pane_current_command} #{pane_width}x#{pane_height}'])
finally:
 run([str(wrapper),'kill-server']);p=Path('/Users/pierre/.no-mistakes/evidence/01M6WYC65Q7211TQMBX0B9X56D/live-overrides.txt');p.write_text('\n'.join(logs));print('\n'.join(logs))
