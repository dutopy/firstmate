import os, pathlib,subprocess,time,signal
R=pathlib.Path.cwd(); W=R/'.test-disk'; H=W/'orca-user'; H.mkdir(exist_ok=True)
env={'HOME':str(H),'XDG_CONFIG_HOME':str(H/'.config'),'XDG_DATA_HOME':str(H/'.local/share'),'TMPDIR':str(W/'tmp'),'PATH':os.environ['PATH'],'SHELL':'/bin/bash'}
E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6K2SH2SRDC8FTMN003XX7QQ/orca-environment.log')
with E.open('w') as f:
 f.write('$ HOME=<disposable workspace home> orca serve --port 17689 --no-pairing --project-root <disposable project> --json\n');f.flush()
 p=subprocess.Popen(['orca','serve','--port','17689','--no-pairing','--project-root',str(W/'project'),'--json'],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
 try:
  time.sleep(8)
  if p.poll() is None:
   f.write('Disposable server remains running after 8 seconds; stopping after capability probe.\n'); f.flush()
 finally:
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  f.write('exit='+str(p.returncode)+'\n')
