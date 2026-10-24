# Reuse only the disposable-home and real CLI driver helpers, not its scenarios.
from pathlib import Path
exec(Path('.test-phase/drive.py').read_text().split("scenario('Monitoring")[0])
h=home('check-sweep'); s=h/'state'; steps=s/'executed'; transcript=[]
try:
    for i in range(10):
        f=s/f'poll{i}.check.sh'; f.write_text(f'#!/bin/bash\nsleep 2\nprintf "poll{i}\\n" >> "{steps}"\n'); f.chmod(0o700)
        r=subprocess.run([str(ROOT/'bin/fm-check-register.sh'),f'poll{i}'],env=env(h),text=True,capture_output=True)
        check(r.returncode==0,r.stderr); transcript.append(r.stdout.strip())
    p,o,e=launch(h,'running'); beat=s/'.last-watcher-beat'; waitfor(beat.exists)
    last=beat.stat().st_mtime_ns; trace=[]; until=time.monotonic()+30
    while time.monotonic()<until:
        n=len(steps.read_text().splitlines()) if steps.exists() else 0
        m=beat.stat().st_mtime_ns
        if m!=last: trace.append({'observed':time.time(),'beacon_mtime_ns':m,'completed_checks':n}); last=m
        if n==10: break
        check(p.poll() is None,'watcher exited: '+e.read_text()); time.sleep(.1)
    check(n==10,'check sweep did not finish'); check(sum(0<x['completed_checks']<10 for x in trace)>=2,'no mid-sweep progress beats')
    (E/'check-sweep.json').write_text(json.dumps({'registrations':transcript,'executed':steps.read_text().splitlines(),'beacon_advances':trace},indent=2))
    results=[dict(name='Running ten registered slow custom checks advances the beacon during the check sweep',result='pass',live=True,evidence=str(E/'check-sweep.json'),reason='')]
    print(json.dumps(results,indent=2)); (E/'sweep-results.json').write_text(json.dumps(results,indent=2))
finally:
    for p in processes: stop(p)
    time.sleep(3); shutil.rmtree(WORK)
