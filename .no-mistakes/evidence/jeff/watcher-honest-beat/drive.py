import os, pathlib, subprocess, time, signal, json, shutil, threading
ROOT=pathlib.Path.cwd(); WORK=ROOT/'.test-phase/live'; WORK.mkdir(parents=True,exist_ok=True)
E=pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M5PKPM7M52DH0Z731MB2BN97')
results=[]; processes=[]
def check(ok,msg):
    if not ok: raise AssertionError(msg)
def waitfor(fn,seconds=15):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        if fn(): return
        time.sleep(.1)
    raise AssertionError('timeout waiting for '+str(fn))
def home(name):
    h=WORK/name; (h/'state').mkdir(parents=True); (h/'config').mkdir(); (h/'tmp').mkdir()
    return h
def env(h):
    e=os.environ.copy()
    for k in list(e):
        if k.startswith(('FM_','TASKS_AXI','TMUX')): e.pop(k,None)
    e.update(HOME=str(h),FM_HOME=str(h),FM_ROOT_OVERRIDE=str(h),TMPDIR=str(h/'tmp'),TMUX_TMPDIR=str(h/'tmp'),FM_GUARD_GRACE='30',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HOME_SUMMARY_INTERVAL='9999999999',FM_GATE_REFUSE_BYPASS='1')
    return e
def launch(h,label):
    out=E/(h.name+'-'+label+'.out'); err=E/(h.name+'-'+label+'.err')
    with out.open('w') as o,err.open('w') as r:
        p=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=env(h),stdout=o,stderr=r,start_new_session=True)
    processes.append(p); return p,out,err
def stop(p):
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGKILL); p.wait()
def frozen(h):
    p,o,e=launch(h,'holder'); s=h/'state'
    waitfor(lambda:(s/'.watch.lock/pid-identity').exists() and (s/'.last-watcher-beat').exists())
    check(int((s/'.watch.lock/pid').read_text())==p.pid,'real holder pid mismatch')
    os.kill(p.pid,signal.SIGSTOP); os.utime(s/'.last-watcher-beat',(946684800,946684800)); return p
def preserve(h):
    d=E/(h.name+'-state'); d.mkdir(exist_ok=True)
    for n in ['.watcher-replace.log','.watcher-replace-loud','.wake-queue','.watch-deliveries.log']:
        f=h/'state'/n
        if f.is_file(): shutil.copyfile(f,d/n)
def scenario(name,fn):
    try:
        detail=fn(); results.append(dict(name=name,result='pass',live=True,evidence=detail,reason=''))
    except Exception as ex:
        results.append(dict(name=name,result='fail',live=True,evidence=str(E/'live-results.json'),reason=str(ex)))
    finally:
        for p in processes: stop(p)

def progress(mode):
    h=home('progress-'+mode); s=h/'state'; handled=s/'big.inbox/handled'; handled.mkdir(parents=True)
    for i in range(3000): (handled/str(i)).touch()
    with (s/'big.status').open('w') as f:
        for i in range(6500): f.write(('needs-decision [key=k%d]: '%(i%40) if mode=='fold' else 'working: ')+('x'*800)+'\n')
    (s/'big.meta').write_text('kind=ship\n')
    p,o,e=launch(h,'scan'); beat=s/'.last-watcher-beat'; waitfor(beat.exists)
    trace=[]; initial=beat.stat().st_mtime_ns; last=initial; until=time.monotonic()+22
    while time.monotonic()<until and p.poll() is None:
        now=beat.stat().st_mtime_ns
        if now!=last: trace.append({'observed':time.time(),'beacon_mtime_ns':now}); last=now
        time.sleep(.1)
    (E/(h.name+'-beacon.json')).write_text(json.dumps({'journal_bytes':(s/'big.status').stat().st_size,'handled_files':3000,'initial_mtime_ns':initial,'advances':trace,'watcher_running':p.poll() is None},indent=2))
    check(p.poll() is None,'watcher exited during long scan: '+o.read_text()+e.read_text())
    check(len(trace)>=2,'beacon did not advance twice during live scan')
    check(not (s/'.watcher-replace.log').exists(),'unexpected replacement')
    return str(E/(h.name+'-beacon.json'))

scenario('Monitoring a 5 MB keyed-decision journal with 3000 handled messages keeps its beacon advancing',lambda:progress('fold'))
scenario('Monitoring a 5 MB working-only journal keeps its beacon advancing',lambda:progress('span'))

def replacement():
    h=home('replacement'); s=h/'state'; old=frozen(h); p,o,e=launch(h,'replacement')
    waitfor(lambda:(s/'.watcher-replace.log').is_file())
    check(old.poll() is None,'budget not recorded before frozen holder exited')
    threading.Thread(target=old.wait,daemon=True).start()
    q,qo,qe=launch(h,'concurrent'); q.wait(timeout=20); p.wait(timeout=20); old.wait(timeout=5)
    check(old.returncode==-9,'frozen holder not killed after TERM grace')
    check(p.returncode==0 and 'check: rearm-resurface' in o.read_text(),'replacement recovery missing')
    check(len((s/'.watcher-replace.log').read_text().splitlines())==1,'duplicate concurrent reservation')
    preserve(h)
    old=frozen(h); q,qo,qe=launch(h,'budget-refusal'); q.wait(timeout=15)
    check(q.returncode!=0 and 'one replacement per 900s' in qe.read_text(),'budget refusal missing')
    check(old.poll() is None,'budget refusal killed holder')
    os.kill(old.pid,signal.SIGCONT); time.sleep(.5)
    check(old.poll() is None or (old.returncode==0 and 'check: rearm-resurface' in (E/'replacement-holder.out').read_text()),'holder terminated without recovery on resume')
    return 'replacement-replacement.out, replacement-concurrent.err, replacement-budget-refusal.err, replacement-state/.watcher-replace.log'
scenario('Rearming replaces a frozen same-home watcher once; concurrent and immediate repeat arms cannot spend a second budget',replacement)

def guard(kind):
    h=home('guard-'+kind); s=h/'state'; old=frozen(h); lock=s/'.watch.lock'
    if kind=='foreign-home': (lock/'fm-home').write_text(str(WORK/'different')+'\n')
    elif kind=='foreign-script': (lock/'watcher-path').write_text('/not-this-watcher\n')
    elif kind=='recycled-identity': (lock/'pid-identity').write_text('invalid-identity\n')
    elif kind=='fresh-beacon': os.utime(s/'.last-watcher-beat',None)
    p,o,e=launch(h,'refused'); p.wait(timeout=15)
    check((p.returncode==0 and 'already running pid' in o.read_text()) if kind=='fresh-beacon' else p.returncode!=0,'holder refusal missing')
    check(old.poll() is None,'holder killed')
    check(not (s/'.watcher-replace.log').exists(),'budget spent for unsafe holder')
    os.kill(old.pid,signal.SIGCONT); time.sleep(.5); check(old.poll() is None,'unsafe holder received deferred TERM')
    return str(e)
for k in ['foreign-home','foreign-script','recycled-identity','fresh-beacon']:
    scenario('Rearming refuses '+k+' without signalling the existing holder',lambda k=k:guard(k))

def loud():
    h=home('loud'); s=h/'state'; now=int(time.time())
    history=''.join(f'{now-25200-i}\t999\t400\n' for i in range(25))+f'{now-2000}\t999\t400\n'
    (s/'.watcher-replace.log').write_text(history); old=frozen(h); p,o,e=launch(h,'repeat')
    threading.Thread(target=old.wait,daemon=True).start()
    p.wait(timeout=25); old.wait(timeout=5)
    check(p.returncode==0 and 'stale: watcher replaced twice in a row' in o.read_text(),'missing repeated-replacement wake')
    check('\tstale\twatcher-replacement\t' in (s/'.wake-queue').read_text(),'not durably queued')
    log=(s/'.watcher-replace.log').read_text(); check(log.startswith(history) and len(log.splitlines())==27,'ledger rewritten/truncated')
    check(not (s/'.watcher-replace-loud').exists(),'delivered marker retained'); preserve(h)
    return 'loud-repeat.out, loud-repeat.err, loud-state/.wake-queue, loud-state/.watcher-replace.log'
scenario('A repeat replacement within six hours uses the latest entry, delivers a durable stale notification, and preserves all history',loud)

def persist(kind):
    h=home('failure-'+kind); s=h/'state'; old=None
    if kind=='queue':
        (s/'.watcher-replace-loud').write_text('watcher replaced twice in a row\n'); (s/'.wake-queue').mkdir()
    else:
        old=frozen(h)
        if kind=='budget': (s/'.watcher-replace.log').mkdir()
        else:
            (s/'.watcher-replace.log').write_text(f'{int(time.time())-2000}\t999\t400\n'); (s/'.watcher-replace-loud').mkdir()
    p,o,e=launch(h,'refusal'); p.wait(timeout=15); check(p.returncode!=0,'persistence failure ignored')
    if old:
        check(old.poll() is None,'holder killed on persistence failure'); os.kill(old.pid,signal.SIGCONT); time.sleep(.5); check(old.poll() is None,'deferred TERM on persistence failure')
        if kind=='publication': check(len((s/'.watcher-replace.log').read_text().splitlines())==2,'reserved budget lost')
    else:
        check((s/'.watcher-replace-loud').is_file(),'lost escalation marker'); (s/'.wake-queue').rmdir()
        q,qo,qe=launch(h,'retry'); q.wait(timeout=15); check(q.returncode==0 and 'stale: watcher replaced twice in a row' in qo.read_text(),'retry failed')
        check(not (s/'.watcher-replace-loud').exists(),'retry retained marker')
    preserve(h); return str(e)+'; '+h.name+'-state'
for k in ['budget','publication','queue']:
    scenario('An unwritable '+k+' path preserves the holder or retains escalation for successful retry',lambda k=k:persist(k))
(E/'live-results.json').write_text(json.dumps(results,indent=2)); print(json.dumps(results,indent=2))
time.sleep(3)
shutil.rmtree(WORK)
