import os, pathlib, subprocess, time, select, signal, json, shutil, ctypes
class Usage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_byte*16)]+[(n,ctypes.c_uint64) for n in ['user','system','pkg','interrupt','wired','resident','footprint','start','exit','child_user','child_system','child_pkg','child_interrupt','child_elapsed','disk_read','disk_write']]
libproc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
def cpu(pid):
    u=Usage()
    if libproc.proc_pid_rusage(pid,2,ctypes.byref(u))!=0: raise OSError(ctypes.get_errno())
    return (u.system+u.child_system)/1e9
ROOT=pathlib.Path.cwd()
TMP=ROOT/'.validation-tmp'
E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M63HV8Q5DZBT9KMY0Z6K3DW8')
BASE='81df10a03ed78be9118e86a2bc9d0497ef3d7b3e'
results=[]

def setup(name, baseline=False, fallback=False):
    d=TMP/name; code=d/'code'; account=d/'account'; state=d/'state'
    (code/'bin').mkdir(parents=True); account.mkdir(); account.chmod(0o700)
    for f in ['fm-remote-job-lib.sh','fm-remote-job-worker.sh']:
        p=code/'bin'/f
        p.write_bytes(subprocess.check_output(['git','show',f'{BASE}:bin/{f}']) if baseline else (ROOT/'bin'/f).read_bytes()); p.chmod(0o755)
    (code/'AGENTS.md').write_text('Disposable remote-job validation fixture\n')
    job=code/'bin'/'fm-touch-job.sh'; job.write_text('#!/bin/bash\nprintf ran > "$1"\n'); job.chmod(0o755)
    env=os.environ.copy(); env.update(HOME=str(account), FM_ROOT_OVERRIDE=str(code), FM_REMOTE_JOB_STATE_ROOT=str(state), FM_REMOTE_JOB_PLATFORM_OVERRIDE='Linux', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(TMP))
    for args in [['init','-q','-b','main'],['add','.'],['-c','user.name=Test','-c','user.email=test@example.com','commit','-qm','fixture']]: subprocess.run(['git','-C',str(code),*args],env=env,check=True)
    if fallback:
        subprocess.run(['/bin/bash','-c','. "$1"; fm_remote_job_prepare_state "$2"', 'setup',str(code/'bin/fm-remote-job-lib.sh'),str(account)],env=env,check=True)
        (state/'worker.wake').unlink(); (state/'worker.wake').touch()
    return d,code,account,state,env

def run(name, baseline=False, fallback=False, pickups=False):
    d,code,account,state,env=setup(name,baseline,fallback)
    err=open(E/(name+'.stderr.log'),'w')
    p=subprocess.Popen(['/bin/bash',str(code/'bin/fm-remote-job-worker.sh'),'--serve'],env=env,stdout=subprocess.DEVNULL,stderr=err)
    try:
        for _ in range(500):
            if (state/'worker.ready').exists(): break
            if p.poll() is not None: raise RuntimeError('worker exited')
            time.sleep(.02)
        else: raise RuntimeError('worker not ready')
        time.sleep(.5)
        k=select.kqueue(); k.control([select.kevent(p.pid,filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD|select.KQ_EV_ENABLE,fflags=select.KQ_NOTE_FORK|select.KQ_NOTE_EXIT)],0,0)
        forks=0; start=time.monotonic(); sys_before=cpu(p.pid); before=(state/'worker.ready').stat().st_mtime_ns
        duration=12
        while time.monotonic()-start<duration:
            for e in k.control(None,4096,.001):
                if e.fflags & select.KQ_NOTE_FORK: forks+=1
        elapsed=time.monotonic()-start
        after=(state/'worker.ready').stat().st_mtime_ns
        sys_delta=cpu(p.pid)-sys_before
        idle={'name':name,'measurement_seconds':elapsed,'worker_direct_fork_events':forks,'direct_processes_per_second_lower_bound':forks/elapsed,'system_cpu_seconds_worker_and_reaped_children':sys_delta,'system_cpu_percent_one_core':100*sys_delta/elapsed,'system_cpu_percent_machine':100*sys_delta/elapsed/os.cpu_count(),'logical_cpus':os.cpu_count(),'heartbeat_advanced':after>before,'heartbeat_age_seconds':time.time()-after/1e9}
        if not baseline and not fallback: assert forks==0, idle
        assert after>before and idle['heartbeat_age_seconds']<2
        k.close()
        probe=subprocess.run(['/bin/bash','-c','. "$1"; fm_remote_job_probe "$2"', 'probe',str(code/'bin/fm-remote-job-lib.sh'),str(account)],env=env,capture_output=True)
        idle['public_liveness_probe_exit']=probe.returncode
        assert probe.returncode==0, probe.stderr
        latency=[]
        if pickups:
            for i in range(6):
                if not fallback:
                    for _ in range(200):
                        marker=state/'worker.waiting'
                        if marker.exists() and marker.read_text().strip()=='1': break
                        time.sleep(.01)
                    else: raise RuntimeError('worker never waited')
                output=d/f'pickup-{i}'; t=time.monotonic()
                script='. "$1"; fm_remote_job_stage "$2" "$3" "$2" fm-touch-job.sh "$4" </dev/null'
                q=subprocess.Popen(['/bin/bash','-c',script,'stage',str(code/'bin/fm-remote-job-lib.sh'),str(account),str(code),str(output)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                published=None; woke=None
                while not output.exists() and time.monotonic()-t<5:
                    now=time.monotonic()
                    if published is None and q.poll() is not None: published=now
                    if not fallback and woke is None and (state/'worker.waiting').read_text().strip()=='0': woke=now
                    time.sleep(.002)
                observed=time.monotonic()
                stdout,stderr=q.communicate(timeout=4)
                assert q.returncode==0,stderr
                assert output.exists(),'job not picked up'
                latency.append({'stage_to_side_effect_seconds':observed-t,'publish_return_to_side_effect_seconds':observed-published if published else None,'stage_to_idle_read_return_seconds':woke-t if woke else None,'job_id':stdout.decode().strip(),'side_effect':output.read_text()})
                time.sleep(.2)
        p.send_signal(signal.SIGTERM)
        pid,status,usage=os.wait4(p.pid,0); p.returncode=os.waitstatus_to_exitcode(status)
        idle.update(total_lifetime_system_cpu_seconds=usage.ru_stime,total_lifetime_user_cpu_seconds=usage.ru_utime,pickups=latency,worker_exit=p.returncode)
        results.append(idle)
        print(json.dumps(idle),flush=True)
    finally:
        if p.returncode is None:
            p.terminate(); p.wait(timeout=15)
        err.close()

for args in [('before',True,False,False),('after',False,False,True),('fallback',False,True,True)]: run(*args)
(E/'live-measurements.json').write_text(json.dumps(results,indent=2)+'\n')
