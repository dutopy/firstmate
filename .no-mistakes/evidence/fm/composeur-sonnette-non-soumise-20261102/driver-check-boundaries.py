import json,time,subprocess
from pathlib import Path
root=Path.cwd();ev=Path('/Users/pierre/.no-mistakes/evidence/01M6FP5GMCE6ECBH8RXVJGNS7T')
for i in range(600):
 if (ev/'pi-partial.handled.txt').exists():break
 time.sleep(1)
else:raise SystemExit('Pi live cases did not finish')
lab=Path((root/'.phase-test/live-lab').read_text().strip());state=lab/'state'
config=state/'pi.native-inbox.config.json';binding=state/'pi.native-inbox.binding.json'
old=json.loads(binding.read_text());before=(lab/'pi.snapshot').read_bytes()
rec=state/'pi.inbox/999.msg';rec.write_text('Boundary probe: must not be delivered.\n')
module=str(root/'bin/fm-native-inbox.mjs')
env=dict(__import__('os').environ);env['PATH']=str(lab/'shim')+':'+env['PATH']
def run(*args):
 r=subprocess.run(['node',module,*map(str,args)],capture_output=True,text=True,env=env)
 return {'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
wrong=run('request','tmux','nativelive:idle',rec,'boundary-probe')
arm=run('arm',state,'pi','pi',lab/'pi-project')
new=json.loads(config.read_text());stale=run('request','tmux','nativelive:pi',rec,'boundary-probe')
time.sleep(1)
unchanged=(lab/'pi.snapshot').read_bytes()==before
result={'wrong_endpoint_request':wrong,'new_generation_arm':arm,'old_generation':old['generation'],'new_generation':new['generation'],'retired_binding_present':binding.exists(),'stale_actor_request':stale,'complete_editor_unchanged':unchanged}
(ev/'live-boundaries.json').write_text(json.dumps(result,indent=2)+'\n')
rec.unlink()
assert wrong['exit']==1 and arm['exit']==0 and old['generation']!=new['generation'] and stale['exit']==1 and not binding.exists() and unchanged
