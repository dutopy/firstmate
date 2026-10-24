from pathlib import Path
exec(Path('.test-phase/drive.py').read_text().split("scenario('Monitoring")[0])
h=home('outside-loud-window'); s=h/'state'; (s/'.watcher-replace.log').write_text(f'{int(time.time())-21660}\t999\t400\n')
try:
    old=frozen(h); p,o,e=launch(h,'replacement'); threading.Thread(target=old.wait,daemon=True).start(); p.wait(timeout=25)
    check(p.returncode==0 and 'check: rearm-resurface' in o.read_text(),'replacement failed')
    check('LOUD' not in e.read_text() and not (s/'.watcher-replace-loud').exists(),'alarm outside six-hour window')
    check(not (s/'.wake-queue').exists() or 'watcher-replacement' not in (s/'.wake-queue').read_text(),'unexpected stale alarm')
    preserve(h)
    r=dict(name='Rearming after the six-hour escalation window replaces the stuck holder without a repeated-replacement alarm',result='pass',live=True,evidence='outside-loud-window-replacement.out; outside-loud-window-replacement.err; outside-loud-window-state/.watcher-replace.log',reason='')
    (E/'quiet-results.json').write_text(json.dumps([r],indent=2)); print(json.dumps(r,indent=2))
finally:
    for p in processes: stop(p)
    time.sleep(3); shutil.rmtree(WORK)
