import pathlib, fcntl, termios, array
exec(compile((pathlib.Path.cwd()/'.validation-tmp/live_check.py').read_text().rsplit('\nfor args in ',1)[0], 'helpers', 'exec'))
d,code,account,state,env=setup('stalled')
log=open(E/'stalled-worker.stderr.log','w')
p=subprocess.Popen(['/bin/bash',str(code/'bin/fm-remote-job-worker.sh'),'--serve'],env=env,stdout=subprocess.DEVNULL,stderr=log)
burst=q=None
try:
    for _ in range(500):
        marker=state/'worker.waiting'
        if marker.exists() and marker.read_text().strip()=='1': break
        time.sleep(.01)
    else: raise RuntimeError('worker did not enter idle read')
    os.kill(p.pid,signal.SIGSTOP)
    progress=d/'progress'
    script='. "$1"; fm_remote_job_prepare_state "$2"; for ((i=0;i<100000;i++)); do fm_remote_job_wake_worker; if ((i%100==0)); then printf "%s\\n" "$i" > "$3"; fi; done; printf complete > "$3"'
    burst=subprocess.Popen(['/bin/bash','-c',script,'burst',str(code/'bin/fm-remote-job-lib.sh'),str(account),str(progress)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    last=None; stable=0; start=time.monotonic()
    while time.monotonic()-start<60:
        time.sleep(.5)
        now=progress.read_text() if progress.exists() else ''
        stable=stable+1 if now==last else 0; last=now
        if stable>=6 or burst.poll() is not None: break
    output=d/'submitted-job-ran'
    script='. "$1"; fm_remote_job_stage "$2" "$3" "$2" fm-touch-job.sh "$4" </dev/null'
    q=subprocess.Popen(['/bin/bash','-c',script,'stage',str(code/'bin/fm-remote-job-lib.sh'),str(account),str(code),str(output)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        stdout,stderr=q.communicate(timeout=4)
        result={'stage_blocked':False,'exit':q.returncode,'stdout':stdout.decode(),'stderr':stderr.decode()}
    except subprocess.TimeoutExpired:
        fd=os.open(state/'worker.wake',os.O_RDONLY|os.O_NONBLOCK)
        unread=array.array('i',[0]); fcntl.ioctl(fd,termios.FIONREAD,unread)
        drained=os.read(fd,16384); os.close(fd)
        result={'stage_blocked':True,'waited_seconds':4,'notification_progress':last.strip(),'unread_fifo_bytes':unread[0],'notification_bytes_drained':len(drained),'worker_waiting_marker':marker.read_text().strip(),'durably_queued_jobs':len(list((state/'jobs').glob('job-*'))),'worker_suspended':True}
    if result.get('stage_blocked'):
        try:
            out,err=q.communicate(timeout=4)
            result['stage_returned_after_draining_fifo_while_worker_stopped']=q.returncode==0
        except subprocess.TimeoutExpired:
            result['stage_returned_after_draining_fifo_while_worker_stopped']=False
    if burst.poll() is None: burst.kill()
    burst.communicate()
    os.kill(p.pid,signal.SIGCONT)
    stdout,stderr=q.communicate(timeout=10)
    result['stage_exit_after_worker_resumed']=q.returncode
    result['stage_stdout_after_worker_resumed']=stdout.decode().strip()
    for _ in range(500):
        if output.exists(): break
        time.sleep(.01)
    result['queued_job_executed_after_worker_resumed']=output.exists()
    print(json.dumps(result,indent=2))
    (E/'stalled-publisher.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
    for proc in [q,burst]:
        if proc is not None and proc.poll() is None: proc.kill(); proc.wait()
    os.kill(p.pid,signal.SIGCONT); p.terminate(); p.wait(timeout=15); log.close()
