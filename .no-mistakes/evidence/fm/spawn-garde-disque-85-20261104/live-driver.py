import os, pathlib, subprocess, json, time
R=pathlib.Path.cwd(); W=R/'.test-disk'; E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6K2SH2SRDC8FTMN003XX7QQ'); B=W/'bin'; B.mkdir(exist_ok=True)
H=W/'user'; H.mkdir(exist_ok=True); F=W/'home'
for d in ['data','state','config','projects']: (F/d).mkdir(parents=True,exist_ok=True)
(F/'state/.last-watcher-beat').touch(); (F/'config/crew-harness').write_text('codex\n')
SOCK=str(W/'s')
(B/'tmux').write_text('#!/bin/bash\nexec /usr/local/bin/tmux -S '+SOCK+' "$@"\n')
(B/'df').write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$DISK_LOG"
n=$(wc -l < "$DISK_LOG")
pct=$(head -n "$n" "$DISK_VALUES" | tail -n 1)
[ "$pct" != error ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n'
printf '/dev/disposable 100 85 15 %s%% /disposable\\n' "$pct"
''')
(B/'codex').write_text('#!/bin/bash\nprintf "disposable replacement received\\n"\n')
for p in B.iterdir(): p.chmod(0o755)
env=os.environ.copy()
for key in ['TMUX','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND','CLAUDE_CONFIG_DIR','TREEHOUSE_ROOT']: env.pop(key,None)
env.update(HOME=str(H), XDG_CONFIG_HOME=str(H/'.config'), SHELL='/bin/bash', PATH=str(B)+':'+os.environ['PATH'], FM_HOME=str(F), FM_STATE_OVERRIDE=str(F/'state'), FM_DATA_OVERRIDE=str(F/'data'),FM_CONFIG_OVERRIDE=str(F/'config'),FM_PROJECTS_OVERRIDE=str(F/'projects'), FM_ROOT_OVERRIDE='',FM_GATE_REFUSE_BYPASS='1',FM_SPAWN_NO_GUARD='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Disposable',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Disposable',GIT_COMMITTER_EMAIL='test@example.invalid', DISK_LOG=str(W/'df.log'),DISK_VALUES=str(W/'values'),TMPDIR=str(W/'tmp'))
(H/'.bashrc').write_text('export PATH='+str(B)+':'+os.environ['PATH']+'\nexport SHELL=/bin/bash\n')
log=open(E/'live-spawn.log','w',buffering=1)
def run(args, check=True, timeout=90):
 p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+'[exit '+str(p.returncode)+']\n')
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p

def inventory(proj):
 run(['tmux','list-windows','-a','-F','#{window_id} #{window_name} #{pane_current_path}'])
 return run(['git','-C',proj,'worktree','list','--porcelain']).stdout

def disk(vals):
 (W/'values').write_text('\n'.join(map(str,vals))+'\n'); (W/'df.log').write_text('')

def setup(name):
 p=W/name; p.mkdir(exist_ok=True); run(['git','init','-b','main',p]); (p/'README').write_text('Disposable live spawn fixture\n'); run(['git','-C',p,'add','.']); run(['git','-C',p,'commit','-m','fixture']); (p/'treehouse.toml').write_text('root = "'+str(W/'pool')+'"\nmax_trees = 10\n'); return p

def spawn(id,proj,scout=False,relaunch=False):
 d=F/'data'/id; d.mkdir(exist_ok=True); (d/'brief.md').write_text('# Task\n## Captain\'s intent\nValidate disk refusal in a disposable fixture.\n## Firstmate spec\nRecord receipt only.\n')
 args=[R/'bin/fm-spawn.sh',id]
 if relaunch: args+=['--relaunch','--harness','codex']
 else: args += [proj, "printf 'disposable worker launch received\\n'", '--backend','tmux'] + (['--scout'] if scout else ['--mode','no-mistakes','--yolo','off'])
 return run(args,False)
results=[]
def record(name): results.append(name); log.write('SCENARIO VERIFIED: '+name+'\n')
try:
 run(['tmux','-f','/dev/null','new-session','-d','-x','120','-y','40','-s','firstmate','-n','untouched','/bin/bash --noprofile --norc'])
 run(['tmux','set-option','-g','default-shell','/bin/bash']); run(['tmux','set-option','-g','default-command','/bin/bash --noprofile --norc'])
 proj=setup('project')
 for pct,scout in [(85,False),(96,True),(100,False)]:
  id='refuse'+str(pct); disk([pct]); env.update(FM_SPAWN_DISK_MAX_PCT='0',FM_SPAWN_DISK_OVERRIDE='1')
  p=spawn(id,proj,scout); assert p.returncode and 'refusing a new worktree' in p.stdout
  assert not (F/'state'/f'{id}.meta').exists(); assert inventory(proj).count('worktree ')==1
  assert 'fm-'+id not in run(['tmux','list-windows','-a','-F','#{window_name}']).stdout
  log.write('Measured targets: '+(W/'df.log').read_text()); assert (W/'df.log').read_text().strip()=='-P /System/Volumes/Data'
  record(f'{pct}% '+('scout' if scout else 'ship')+' refuses without allocation/publication, removed bypass variables ineffective')
 for scout in [False,True]:
  id='rising-scout' if scout else 'rising-ship'; disk([84,85]); before=inventory(proj)
  p=spawn(id,proj,scout); assert p.returncode and '85%' in p.stdout
  assert not (F/'state'/f'{id}.meta').exists(); assert inventory(proj)==before
  windows=run(['tmux','list-windows','-a','-F','#{window_name}']).stdout
  assert 'untouched' in windows and 'fm-'+id not in windows
  assert len((W/'df.log').read_text().splitlines())==2
  record(id+' 84→85 refuses at allocation and closes only new endpoint')
  disk([84]); p=spawn(id,proj,scout); assert p.returncode==0
  meta=(F/'state'/f'{id}.meta').read_text(); log.write('Published task record:\n'+meta)
  wt=pathlib.Path(next(x[9:] for x in meta.splitlines() if x.startswith('worktree=')))
  assert wt.is_dir() and wt!=proj; inventory(proj)
  run(['tmux','capture-pane','-p','-t','firstmate:fm-'+id,'-S','-12'])
  record(id+' retry at 84% succeeds with real Treehouse/Git and no orphan conflict')
  if not scout:
   (wt/'uncommitted.txt').write_text('preserve this work\n'); before=inventory(proj); disk([100]); p=spawn(id,proj,relaunch=True)
   assert p.returncode==0; assert (wt/'uncommitted.txt').read_text()=='preserve this work\n'; assert inventory(proj)==before; assert not (W/'df.log').read_text()
   run(['git','-C',wt,'status','--short']); record('existing-worktree relaunch at 100% preserves dirty work, endpoint, and inventory without disk probe')
 # Exercise the non-macOS target policy via a controlled platform probe; the
 # running spawn, terminal, Git, and allocator remain the real executables.
 (B/'uname').write_text('#!/bin/bash\nif [ "${1:-}" = -s ]; then echo Linux; else exec /usr/bin/uname "$@"; fi\n'); (B/'uname').chmod(0o755)
 cases=[('env',str(W/'env-root/missing/leaf'),str(W)),('config',None,str(W/'config-root')),('default',None,str(H/'.treehouse'))]
 for name,root,expected in cases:
  if root: env['TREEHOUSE_ROOT']=root
  else: env.pop('TREEHOUSE_ROOT',None)
  if name=='config':
   (W/'config-root').mkdir(exist_ok=True); (proj/'treehouse.toml').write_text('root = "'+str(W/'config-root/missing')+'"\n')
  if name=='default': (proj/'treehouse.toml').unlink()
  disk([85]); p=spawn('target-'+name,proj); assert p.returncode and 'refusing a new worktree' in p.stdout
  observed=(W/'df.log').read_text(); log.write('Measured target: '+observed); assert observed.strip()=='-P '+expected
  record('non-Data '+name+' root resolves nearest existing ancestor before refusal')
 # User configuration wins when no project config exists.
 (H/'.config/treehouse').mkdir(parents=True,exist_ok=True)
 (H/'.config/treehouse/config.toml').write_text('root = "'+str(W/'config-root/missing')+'"\n')
 disk([85]); p=spawn('target-user-config',proj); assert p.returncode and (W/'df.log').read_text().strip()=='-P '+str(W/'config-root')
 record('non-Data user Treehouse config root is measured')
 (B/'uname').unlink()
 for value,expected in [('error','cannot measure disk usage'),('invalid','unreadable disk usage')]:
  disk([value]); p=spawn('probe-'+value,proj); assert p.returncode and expected in p.stdout
  assert not (F/'state'/('probe-'+value+'.meta')).exists()
  record('unavailable disk probe '+value+' refuses rather than allocating')
 (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
 run(['tmux','kill-server'],False)
 log.close()
