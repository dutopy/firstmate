import os, pathlib, subprocess, json, shutil, time
root=pathlib.Path.cwd(); base=root/'.test-phase/live'; base.mkdir()
evidence=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6KA7RX9FKYXRMEN7ZY0NEDE')
real_tmux=shutil.which('tmux'); original_path=os.environ['PATH']
results=[]; transcript=[]
def run(args,env,cwd=None):
    return subprocess.run(args,env=env,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
for name,pct,flag,reason,want,kind in [
 ('below', '84',None,None,True,'ship'),('threshold','85',None,None,False,'ship'),('full','100',None,None,False,'ship'),
 ('cleanup','96','1','cleanup',True,'ship'),('scout-short','96','1','x',True,'scout'),('long','96','1','x'*201,True,'ship'),
 ('missing-reason','96','1',None,False,'ship'),('reason-only','96',None,'cleanup',False,'ship'),('wrong-flag','96','true','cleanup',False,'ship'),
 ('blank','96','1','   ',False,'ship'),('newline','96','1','cleanup\nforged',False,'ship'),('control','96','1','cleanup\tworker',False,'ship'),
 ('unreadable','bad','1','cleanup',False,'ship'),('df-failure','error','1','cleanup',False,'ship'),('journal-failure','96','1','cleanup',False,'ship'),
 ('rising','rising',None,None,False,'ship')]:
    d=base/name; d.mkdir(); home=d/'home'; project=d/'project'; tools=d/'tools'; user=d/'user'; socket=root/'.ts'
    for x in [home/'state',home/'data'/name,home/'config',home/'projects',tools,user,project]: x.mkdir(parents=True,exist_ok=True)
    (home/'state/.last-watcher-beat').touch(); (home/'config/crew-harness').write_text('codex\n')
    (home/'data'/name/'brief.md').write_text("# Task\n## Captain's intent\nExercise disposable disk override.\n## Firstmate spec\nNo external work.\n")
    (tools/'tmux').write_text(f'#!/bin/bash\nexec {real_tmux} -S "{socket}" "$@"\n')
    (tools/'df').write_text(f'''#!/bin/bash
n=0; [ ! -f '{d}/df-count' ] || n=$(< '{d}/df-count'); n=$((n+1)); echo "$n" > '{d}/df-count'
pct='{pct}'
[ "$pct" != error ] || exit 1
if [ "$pct" = rising ]; then if [ "$n" -eq 1 ]; then pct=84; else pct=85; fi; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disposable 100 96 4 %s%% /disposable\n' "$pct"
''')
    (tools/'codex').write_text(f'#!/bin/bash\nprintf "worker payload reached: %s\\n" "$PWD" > "{d}/worker-started"\nexec /bin/sleep 120\n')
    for x in tools.iterdir(): x.chmod(0o755)
    for rc in ['.bash_profile','.bashrc']:
        (user/rc).write_text('export PATH="'+str(tools)+':'+original_path+'"\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TREEHOUSE_','TASKS_AXI_','GIT_','CODEX_','CLAUDE_'))}
    env.update(HOME=str(user),XDG_CONFIG_HOME=str(user/'.config'),PATH=str(tools)+':'+original_path,SHELL='/bin/bash',TMPDIR=str(root/'.test-phase/tmp'),FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_PROJECTS_OVERRIDE=str(home/'projects'),FM_SPAWN_NO_GUARD='1',FM_GATE_REFUSE_BYPASS='1',TREEHOUSE_ROOT=str(d/'pool'),FM_SPAWN_ISOLATION_WAIT_SECS='20',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
    if flag is not None: env['FM_SPAWN_DISK_OVERRIDE']=flag
    if reason is not None: env['FM_SPAWN_DISK_OVERRIDE_REASON']=reason
    for args in [['git','init','-q',str(project)],['git','-C',str(project),'config','user.name','Disposable'],['git','-C',str(project),'config','user.email','disposable@example.invalid'],['git','-C',str(project),'commit','-qm','initial','--allow-empty']]:
        p=run(args,env); assert p.returncode==0,p.stdout
    (project/'treehouse.toml').write_text('max_trees = 2\n')
    if name=='journal-failure': (home/'state/spawn-disk-overrides.log').mkdir()
    p=run(['tmux','-f','/dev/null','new-session','-d','-s','firstmate','-x','100','-y','30','-c',str(project)],env); assert p.returncode==0,p.stdout
    run(['tmux','set-option','-g','default-shell','/bin/bash'],env)
    env['TMUX']=str(socket)+',1,0'
    try:
        args=[str(root/'bin/fm-spawn.sh'),name,str(project),'--backend','tmux']+(['--scout'] if kind=='scout' else ['--mode','no-mistakes','--yolo','off'])
        p=run(args,env)
        transcript.append(f'=== {name}: disk={pct}, override={flag!r}, reason={reason!r} ===\n$ fm-spawn.sh {name} <disposable-project> '+(' --scout' if kind=='scout' else '--mode no-mistakes --yolo off')+f' --backend tmux\n{p.stdout}\nexit={p.returncode}\n')
        meta=home/'state'/f'{name}.meta'; journal=home/'state/spawn-disk-overrides.log'
        windows=run(['tmux','list-windows','-t','firstmate','-F','#{window_name}'],env).stdout
        transcript.append('Remaining windows:\n'+windows)
        if want:
            assert p.returncode==0,p.stdout
            assert meta.exists(),'no task publication'
            state=meta.read_text(); wt=next(line[9:] for line in state.splitlines() if line.startswith('worktree='))
            assert run(['git','-C',wt,'rev-parse','--is-inside-work-tree'],env).returncode==0
            assert pathlib.Path(wt)!=project
            transcript.append('Published metadata:\n'+state)
            for _ in range(20):
                if (d/'worker-started').exists(): break
                time.sleep(.2)
            pane=run(['tmux','capture-pane','-p','-t','firstmate:fm-'+name,'-S','-80'],env).stdout
            transcript.append('Actual worker terminal:\n'+pane)
            assert (d/'worker-started').exists(),'payload not started: '+pane
            transcript.append((d/'worker-started').read_text())
            if flag=='1':
                lines=journal.read_text().splitlines(); assert len(lines)==2,lines
                assert all(f'task={name} disk_percent=96 threshold=85 reason={reason}' in l for l in lines)
                assert 'warning: disk override' in p.stdout
                assert 'disk_override=' not in state
                status=home/'state'/f'{name}.status'
                assert not status.exists() or 'disk_override=' not in status.read_text()
                transcript.append('Sole audit journal:\n'+journal.read_text())
            else: assert not journal.exists()
        else:
            assert p.returncode!=0,'unexpected success'
            assert not meta.exists(),'task published on refusal'
            assert not list((d/'pool').rglob('.git')),'worktree allocated on refusal'
            assert 'fm-'+name not in windows,'orphan window'
            if name=='journal-failure': assert 'cannot journal disk override' in p.stdout
            elif name=='df-failure': assert 'cannot measure disk usage' in p.stdout
            elif name=='unreadable': assert 'unreadable disk usage' in p.stdout
            else: assert 'threshold 85%' in p.stdout
        results.append(dict(name=name,result='pass'))
    except Exception as e:
        transcript.append('CHECK FAILURE: '+str(e)); results.append(dict(name=name,result='fail',reason=str(e)))
    finally:
        run(['tmux','kill-server'],env)
(evidence/'live-spawn-transcript.log').write_text('\n'.join(transcript))
(evidence/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
