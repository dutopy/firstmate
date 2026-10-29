import pathlib, fcntl, termios, array
helpers=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M63HV8Q5DZBT9KMY0Z6K3DW8/live_check_round2.py').read_text().rsplit('\nfor args in ',1)[0]
exec(compile(helpers,'live-helpers','exec'))
d,code,account,state,env=setup('saturation-round2')
log=open(E/'saturation-round2.stderr.log','w')
p=subprocess.Popen(['/bin/bash',str(code/'bin/fm-remote-job-worker.sh'),'--serve'],env=env,stdout=subprocess.DEVNULL,stderr=log)
q=None; fd=None
try:
    marker=state/'worker.waiting'
    for _ in range(500):
        if marker.exists() and marker.read_text().strip()=='1': break
        time.sleep(.01)
    else: raise RuntimeError('real worker never advertised waiting')
    os.kill(p.pid,signal.SIGSTOP)
    _, stopped = os.waitpid(p.pid, os.WUNTRACED)
    assert os.WIFSTOPPED(stopped)
    marker.write_text('1\n')
    fd=os.open(state/'worker.wake',os.O_RDWR|os.O_NONBLOCK)
    filled=0
    for size in [4096,1]:
        while True:
            try: filled+=os.write(fd,b'x'*size)
            except BlockingIOError: break
    unread=array.array('i',[0])
    fcntl.ioctl(fd,termios.FIONREAD,unread)
    output=d/'job-ran'
    t=time.monotonic()
    q=subprocess.Popen(['/bin/bash','-c','. "$1"; fm_remote_job_stage "$2" "$3" "$2" fm-touch-job.sh "$4" </dev/null','stage',str(code/'bin/fm-remote-job-lib.sh'),str(account),str(code),str(output)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    out,err=q.communicate(timeout=4)
    elapsed=time.monotonic()-t
    assert q.returncode==0,err
    job=out.decode().strip()
    queued=(state/'jobs'/job/'state').read_text().strip()
    assert queued=='queued',queued
    assert not output.exists()
    result={'worker_shell':'/bin/bash 3.2.57','suspended_real_worker':True,'stale_waiting_marker':marker.read_text().strip(),'saturated_fifo_bytes':unread[0],'notification_bytes_written':filled,'stage_elapsed_seconds':elapsed,'stage_exit':q.returncode,'stage_stdout':job,'persisted_job_state_before_resume':queued,'job_ran_while_suspended':output.exists()}
    try:
        while os.read(fd,65536): pass
    except BlockingIOError: pass
    os.close(fd); fd=None
    os.kill(p.pid,signal.SIGCONT)
    for _ in range(500):
        if output.exists() and (state/'jobs'/job/'state').read_text().strip()=='done': break
        time.sleep(.01)
    assert output.exists()
    result['side_effect_after_resume']=output.read_text()
    result['job_state_after_resume']=(state/'jobs'/job/'state').read_text().strip()
    assert result['job_state_after_resume']=='done'
    print(json.dumps(result,indent=2))
    (E/'saturation-round2.json').write_text(json.dumps(result,indent=2)+'\n')
finally:
    if fd is not None: os.close(fd)
    if q is not None and q.poll() is None: q.kill(); q.wait()
    os.kill(p.pid,signal.SIGCONT); p.terminate(); p.wait(timeout=15); log.close()
