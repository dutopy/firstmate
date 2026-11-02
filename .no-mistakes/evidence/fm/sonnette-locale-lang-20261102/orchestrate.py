import os,subprocess,pathlib,time
root=pathlib.Path.cwd();lab=root/'.test-lab';ev=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M6E9WDM51BZDDFZG5H6CW49E')
subprocess.run(['tmux','-S',str(lab/'tmux.sock'),'kill-server'],stderr=subprocess.DEVNULL)
with open(lab/'server.log','w') as log:
 server=subprocess.Popen(['tmux','-D','-f','/dev/null','-S',str(lab/'tmux.sock')],env=dict(os.environ,HOME=str(lab/'agent-home')),stdout=log,stderr=log)
 try:
  time.sleep(1)
  subprocess.run(['python3',str(lab/'start-live.py')],check=True)
  time.sleep(5)
  with open(ev/(os.environ.get('RUN_LABEL','')+'live-delivery.log'),'w') as out:
   p=subprocess.run(['bash',str(lab/'live-check.sh')],stdout=out,stderr=subprocess.STDOUT)
  print('driver exit',p.returncode,'server status',server.poll())
  print((ev/(os.environ.get('RUN_LABEL','')+'live-delivery.log')).read_text())
  print(subprocess.run(['tmux','-S',str(lab/'tmux.sock'),'capture-pane','-p','-t','live:worker'],capture_output=True,text=True).stdout)
  if p.returncode==0:
   with open(ev/'adversarial.log','w') as out:
    guard=subprocess.run(['bash',str(lab/'adversarial-check.sh')],stdout=out,stderr=subprocess.STDOUT)
   print('adversarial exit',guard.returncode)
   print((ev/'adversarial.log').read_text())
 finally:
  subprocess.run(['tmux','-S',str(lab/'tmux.sock'),'kill-server'],stderr=subprocess.DEVNULL)
  server.terminate();server.wait()
