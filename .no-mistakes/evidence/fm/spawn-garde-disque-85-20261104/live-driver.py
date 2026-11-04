import os, pathlib, subprocess, json, shutil, time
R=pathlib.Path.cwd(); D=R/'.test-disposable/live'; E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6K3SFG7FC4HHDCZA87J5EHY'); D.mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_', 'TREEHOUSE_', 'TMUX', 'CLAUDE_', 'CODEX_', 'NO_MISTAKES_')): env.pop(k,None)
env.update(HOME=str(D/'user'), XDG_CONFIG_HOME=str(D/'user/.config'), XDG_CACHE_HOME=str(D/'user/.cache'), TMPDIR=str(R/'.test-disposable/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', SHELL='/bin/bash')
(D/'user').mkdir(exist_ok=True); (D/'tools').mkdir(exist_ok=True)
real_tmux=shutil.which('tmux'); socket=str(R/'.s'); env['PATH']=str(D/'tools')+':'+env['PATH']
log=open(E/'live-cli.log','w',buffering=1)
def run(args,check=True,cwd=None,extra=None):
    ee=env.copy(); ee.update(extra or {})
    p=subprocess.run([str(x) for x in args],env=ee,cwd=cwd or R,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'\nexit={p.returncode}\n')
    if check and p.returncode: raise RuntimeError(p.stdout)
    return p

def tool(name,body):
    f=D/'tools'/name; f.write_text(body); f.chmod(0o755)
tool('tmux',f'#!/bin/bash\nexec {real_tmux} -S {socket} "$@"\n')
tool('df','''#!/bin/bash
n=0; [ ! -f "$DISK_COUNT" ] || read n < "$DISK_COUNT"
n=$((n+1)); echo "$n" > "$DISK_COUNT"
read pct next < "$DISK_SETTING"
[ "$n" -le 1 ] || pct=${next:-$pct}
printf '%s: %s => %s%%\\n' "$n" "$*" "$pct" >> "$DISK_LOG"
if [ "$pct" = error ]; then exit 1; fi
if [ "$pct" = malformed ]; then echo 'bad df output'; exit 0; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/disposable 100 84 16 %s%% /disposable volume\\n' "$pct"
''')
# Only the post-allocation AI consumer is inert: terminals, allocator, Git and Firstmate are real.
tool('codex','#!/bin/bash\nprintf "DISPOSABLE_AGENT_RECEIVED_BRIEF\\n"\nexit 0\n')
# Treehouse starts a login shell: re-pin PATH after macOS /etc/profile runs.
(D/'user/.bash_profile').write_text('export PATH="'+env['PATH']+'"\n')
(D/'user/.bashrc').write_text('export PATH="'+env['PATH']+'"\n')
env.update(DISK_COUNT=str(D/'count'),DISK_SETTING=str(D/'setting'),DISK_LOG=str(D/'df.log'))
conf=D/'tmux.conf'; conf.write_text('set -g default-shell /bin/bash\nset -g default-command "/bin/bash --noprofile --norc"\nset -g status off\n')
P=D/'project'; P.mkdir(exist_ok=True)
run(['git','init','-b','main',P]); run(['git','-C',P,'config','user.email','disposable@example.invalid']); run(['git','-C',P,'config','user.name','Disposable'])
(P/'README.md').write_text('Disposable product verification\n'); (P/'treehouse.toml').write_text('max_trees = 8\n')
run(['git','-C',P,'add','.']); run(['git','-C',P,'commit','-m','Disposable seed'])
H=D/'home'
for part in ['state','data','config','projects']: (H/part).mkdir(parents=True,exist_ok=True)
(H/'config/crew-harness').write_text('codex\n'); (H/'state/.last-watcher-beat').touch()
env.update(FM_HOME=str(H),FM_STATE_OVERRIDE=str(H/'state'),FM_DATA_OVERRIDE=str(H/'data'),FM_CONFIG_OVERRIDE=str(H/'config'),FM_PROJECTS_OVERRIDE=str(H/'projects'),FM_ROOT_OVERRIDE='',FM_GATE_REFUSE_BYPASS='1',FM_SPAWN_NO_GUARD='1',TREEHOUSE_ROOT=str(D/'pool'),FM_SPAWN_ISOLATION_WAIT_SECS='20',CLAUDE_CONFIG_DIR='')
results=[]
def disk(pct,next=None):
    (D/'setting').write_text(f'{pct} {next or pct}\n'); (D/'count').write_text('0\n')
def spawn(id,scout=False,extra=None):
    b=H/'data'/id; b.mkdir(exist_ok=True); (b/'brief.md').write_text("# Task\n## Captain's intent\nVerify disposable disk refusal.\n\n## Firstmate spec\nExercise spawn.\n")
    args=[R/'bin/fm-spawn.sh',id,P,'--backend','tmux']+(['--scout'] if scout else ['--mode','no-mistakes','--yolo','off'])
    return run(args,check=False,extra=extra)
def inventory():
    w=run(['tmux','list-windows','-t','firstmate','-F','#{window_id} #{window_name} #{pane_current_path}']).stdout
    g=run(['git','-C',P,'worktree','list','--porcelain']).stdout
    return w,g
try:
    run(['tmux','-f',conf,'new-session','-d','-s','firstmate','-n','untouched','-x','120','-y','40'])
    original=inventory()
    for name,pct,scout in [('exact-85',85,False),('scout-96',96,True),('full-100',100,False),('obsolete-bypass',96,False)]:
        disk(pct); p=spawn(name,scout,{'FM_SPAWN_DISK_MAX_PCT':'0','FM_SPAWN_DISK_OVERRIDE':'1'} if name=='obsolete-bypass' else None)
        assert p.returncode!=0 and 'threshold 85%' in p.stdout
        assert inventory()==original and not (H/'state'/f'{name}.meta').exists()
        results.append(name+': refused; unchanged endpoint and Git inventory; no metadata')
    for id,scout in [('rising-ship',False),('rising-scout',True)]:
        disk(84,85); p=spawn(id,scout)
        assert p.returncode!=0 and '85% used' in p.stdout
        assert inventory()==original and not (H/'state'/f'{id}.meta').exists()
        assert (D/'count').read_text().strip()=='2'
        results.append(id+': 84 -> 85 refused at allocation; only newly created window removed')
        disk(84); p=spawn(id,scout)
        assert p.returncode==0, p.stdout
        meta=(H/'state'/f'{id}.meta').read_text(); log.write('PERSISTED '+meta+'\n')
        wt=pathlib.Path(next(l[9:] for l in meta.splitlines() if l.startswith('worktree=')))
        assert wt.is_dir(); assert str(wt) in inventory()[1]
        run(['tmux','capture-pane','-p','-t',f'firstmate:fm-{id}'])
        results.append(id+': retry at 84 allocated a real Treehouse/Git worktree and published metadata')
        run(['tmux','kill-window','-t',f'firstmate:fm-{id}'])
        # Leave real allocated worktrees present; baseline now includes these untouched copies.
        original=inventory()
    # A below-threshold ship proves the unqualified happy path too.
    disk(84); p=spawn('below'); assert p.returncode==0,p.stdout
    results.append('below: 84 allocated and published')
    inventory(); run(['tmux','capture-pane','-p','-t','firstmate:fm-below'])
    meta=(H/'state/below.meta').read_text()
    wt=pathlib.Path(next(l[9:] for l in meta.splitlines() if l.startswith('worktree=')))
    (wt/'uncommitted.txt').write_text('must survive relaunch\n')
    time.sleep(3)  # Wait for the inert consumer to exit, leaving a positively agent-free shell.
    before=inventory(); disk(100)
    p=run([R/'bin/fm-spawn.sh','below','--relaunch'],check=False)
    assert p.returncode==0,p.stdout
    assert inventory()==before
    assert (wt/'uncommitted.txt').read_text()=='must survive relaunch\n'
    assert (D/'count').read_text().strip()=='0'
    log.write('PRESERVED DIRTY FILE: '+(wt/'uncommitted.txt').read_text())
    results.append('relaunch: at 100 reused the exact endpoint and worktree; uncommitted file preserved; no disk probe')
    for id,pct in [('unreadable-df','malformed'),('failed-df','error')]:
        disk(pct); before=inventory(); p=spawn(id)
        assert p.returncode!=0 and 'refusing spawn' in p.stdout
        assert inventory()==before and not (H/'state'/f'{id}.meta').exists()
        results.append(id+': refused without allocation, publication or endpoint change')
    # Exercise fallback selection via the real CLI with only platform/disk probes controlled.
    tool('uname','#!/bin/bash\nif [ "${1:-}" = -s ]; then echo Linux; else exec /usr/bin/uname "$@"; fi\n')
    for name,root,config,target in [
        ('env-root',str(D/'not-created/pool'), 'max_trees = 8\n',str(D)),
        ('config-root','', 'root = "../configured/not-created"\n',str(D)),
        ('default-root','', 'max_trees = 8\n',str(D/'user/.treehouse') if (D/'user/.treehouse').is_dir() else str(D/'user')),
    ]:
        (P/'treehouse.toml').write_text(config)
        disk(85); before=inventory(); p=spawn(name,extra={'TREEHOUSE_ROOT':root})
        assert p.returncode!=0 and 'is 85% used' in p.stdout,p.stdout
        measured=p.stdout.split('disk at ',1)[1].split(' is 85%',1)[0]
        assert pathlib.Path(measured).resolve()==pathlib.Path(target).resolve(),p.stdout
        assert inventory()==before and not (H/'state'/f'{name}.meta').exists()
        results.append(name+': fallback measured nearest existing ancestor '+target+' and refused')
    # User config is selected when the primary checkout has no Treehouse config.
    (P/'treehouse.toml').unlink()
    uc=D/'user/.config/treehouse'; uc.mkdir(parents=True,exist_ok=True)
    (uc/'config.toml').write_text('root = "'+str(D/'user-config/missing')+'"\n')
    disk(85); p=spawn('user-config-root',extra={'TREEHOUSE_ROOT':''})
    assert p.returncode!=0 and f'disk at {D} is 85%' in p.stdout,p.stdout
    results.append('user-config-root: selected user config and nearest existing ancestor; refused')
    log.write('DF TARGETS / MEASUREMENTS\n'+(D/'df.log').read_text())
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('\n'.join(results))
finally:
    run(['tmux','kill-server'],check=False)
    log.close()
