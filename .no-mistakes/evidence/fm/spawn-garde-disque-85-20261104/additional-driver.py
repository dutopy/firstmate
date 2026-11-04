import pathlib, shutil, json
src=pathlib.Path('.test-disk/live.py').read_text().split('results=[]')[0]
src=src.replace("E/'live-spawn.log'", "E/'additional-spawn.log'")
exec(src)
results=[]
def record(name): results.append(name); log.write('SCENARIO VERIFIED: '+name+'\n')
try:
 run(['tmux','-f','/dev/null','new-session','-d','-x','120','-y','40','-s','firstmate','-n','untouched','/bin/bash --noprofile --norc'])
 run(['tmux','set-option','-g','default-shell','/bin/bash']); run(['tmux','set-option','-g','default-command','/bin/bash --noprofile --norc'])
 runtime=W/'runtime'; runtime.mkdir(exist_ok=True)
 shutil.copytree(R/'bin',runtime/'bin',dirs_exist_ok=True)
 shutil.copytree(R/'docs',runtime/'docs',dirs_exist_ok=True)
 sm=W/'secondmate'; (sm/'bin').mkdir(parents=True,exist_ok=True); (sm/'data').mkdir(exist_ok=True)
 shutil.copyfile(R/'AGENTS.md',sm/'AGENTS.md')
 (sm/'.fm-secondmate-home').write_text('disk-secondmate\n'); (sm/'data/charter.md').write_text('Disposable existing-home launch probe.\n')
 env.update(FM_ROOT_OVERRIDE=str(runtime),FM_SKIP_SECONDMATE_SYNC='1',FM_SKIP_SECONDMATE_INHERIT='1')
 disk([100])
 p=run([R/'bin/fm-spawn.sh','disk-secondmate',sm,"printf 'existing secondmate home received launch\\n'",'--secondmate','--backend','tmux'],False)
 assert p.returncode==0; assert not (W/'df.log').read_text()
 log.write((F/'state/disk-secondmate.meta').read_text()); run(['tmux','list-windows','-a','-F','#{window_id} #{window_name} #{pane_current_path}'])
 record('persistent secondmate existing home launches at 100% without disk probe or new worktree')
 (E/'additional-results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
 run(['tmux','kill-server'],False); log.close()
