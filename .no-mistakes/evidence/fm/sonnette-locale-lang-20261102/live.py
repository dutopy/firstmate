import os, pathlib, subprocess as s, time, json, shlex
root=pathlib.Path.cwd(); base=root/'.local-test'; account=base/'account'; evidence=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6E6106M03M17JQ5JDF8HZ4W')
config=base/'c'; config.mkdir(exist_ok=True)
(config/'config.toml').write_text('[terminal]\ndefault_shell = "/bin/bash"\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n')
env=dict(PATH=os.environ['PATH'], HOME=str(account), TMPDIR=str(base/'tmp'), XDG_CONFIG_HOME='.local-test/c', HERDR_CONFIG_PATH='.local-test/c/config.toml', SHELL='/bin/bash', TERM='xterm-256color')
def cmd(args, **kw):
 p=s.run(args,cwd=root,env=env,text=True,capture_output=True,timeout=kw.pop('timeout',30),**kw)
 if p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}\n{p.stderr}')
 return p.stdout
serverlog=open(base/'server.log','w')
server=s.Popen(['herdr','server','--session','fm-lab-locale'],cwd=root,env=env,stdout=serverlog,stderr=serverlog)
try:
 for _ in range(50):
  try:
   st=json.loads(cmd(['herdr','status','--json','--session','fm-lab-locale']))
   if st['server']['running']: break
  except Exception: pass
  time.sleep(.2)
 else: raise RuntimeError('server failed: '+(base/'server.log').read_text())
 out=cmd(['herdr','workspace','create','--cwd',str(base),'--label','locale-validation','--no-focus','--session','fm-lab-locale']); (evidence/'workspace.json').write_text(out)
 pane=json.loads(out)['result']['root_pane']['pane_id']; (base/'pane').write_text(pane)
 print('PANE',pane,flush=True)
 # A real local Pi UI, without operator credentials or configuration.
 run=f'cd {shlex.quote(str(base))} && HOME={shlex.quote(str(account))} PI_CODING_AGENT_DIR={shlex.quote(str(base/"pi"))} pi --no-session'
 print(cmd(['herdr','pane','run',pane,run,'--session','fm-lab-locale']),flush=True)
 time.sleep(8)
 print(cmd(['herdr','pane','read',pane,'--source','recent','--lines','80','--session','fm-lab-locale']),flush=True)
 print(cmd(['herdr','agent','get',pane,'--session','fm-lab-locale']),flush=True)
 (base/'server-pid').write_text(str(server.pid))
except:
 server.terminate(); server.wait(timeout=10); raise
