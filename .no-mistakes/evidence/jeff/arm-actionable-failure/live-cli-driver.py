import os, pathlib, signal, subprocess, time, json

root = pathlib.Path.cwd()
base = root / '.local-validation'
evidence = pathlib.Path('/Users/pierre/.no-mistakes/evidence/01M5WAXQNWMYCZXV3CCHMG25JQ')
watch = root / 'bin/fm-watch.sh'
results = []
transcript = []
for name, age, identity, no_beat, expected in [
    ('verified-late', 120, True, False, 0),
    ('verified-hung', 400, True, False, 1),
    ('foreign-identity-late', 120, False, False, 1),
    ('missing-beat-old-lock', None, True, True, 1),
    ('fresh-beat-startup-exception', 0, False, False, 0),
    ('young-lock-startup-exception', None, False, True, 0),
]:
    home = base / name
    state = home / 'state'
    state.mkdir(parents=True)
    env = dict(os.environ, HOME=str(base / 'home'), TMPDIR=str(base / 'tmp'),
               FM_HOME=str(home), FM_STATE_OVERRIDE=str(state), FM_ROOT_OVERRIDE=str(home),
               FM_GUARD_GRACE='60', FM_POLL='0.2', FM_SIGNAL_GRACE='1',
               FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_HOME_SUMMARY_INTERVAL='999999')
    holder_log = (home / 'holder.log').open('w')
    holder = subprocess.Popen([str(watch)], env=env, stdout=holder_log, stderr=holder_log,
                              start_new_session=True)
    try:
        deadline = time.monotonic() + 15
        beat = state / '.last-watcher-beat'
        lock = state / '.watch.lock'
        while not (beat.exists() and (lock / 'pid-identity').exists()):
            if holder.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('actual watcher failed to publish identity and heartbeat')
            time.sleep(.02)
        os.killpg(holder.pid, signal.SIGSTOP)
        time.sleep(.1)
        now = int(time.time())
        (state / '.watcher-replace.log').write_text(f'{now}\t{holder.pid}\t1\n')
        if not identity:
            (lock / 'pid-identity').write_text('deliberately wrong process identity\n')
        if no_beat:
            beat.unlink()
            lock_age = 120 if name == 'missing-beat-old-lock' else 0
            os.utime(lock, (now-lock_age, now-lock_age), follow_symlinks=False)
        else:
            os.utime(beat, (now-age, now-age))
        run = subprocess.run([str(watch)], env=env, capture_output=True, text=True, timeout=15)
        os.kill(holder.pid, 0)
        transcript.append(f'=== {name} (real watcher holder pid={holder.pid}) ===\n'
                          f'$ FM_HOME=<disposable> FM_GUARD_GRACE=60 bin/fm-watch.sh\n'
                          f'exit={run.returncode}; holder remains alive\nSTDOUT:\n{run.stdout}STDERR:\n{run.stderr}')
        assert run.returncode == expected, transcript[-1]
        if name == 'verified-late':
            assert 'identity verified; hard limit 180s)' in run.stdout and 'FAILED' not in run.stdout
        elif name == 'verified-hung':
            assert 'reason=stale-hung' in run.stdout and 'heartbeat is stale' in run.stderr
        elif name == 'foreign-identity-late':
            assert 'reason=identity-mismatch' in run.stdout and 'heartbeat is stale' in run.stderr
        elif name == 'missing-beat-old-lock':
            assert 'reason=lock-unverifiable' in run.stdout and 'no heartbeat exists' in run.stderr
        else:
            assert f'watcher: already running pid {holder.pid}' in run.stdout
        results.append({'name': name, 'exit': run.returncode, 'result': 'pass'})
    finally:
        try:
            os.killpg(holder.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        holder.wait(timeout=5)
        holder_log.close()
        (evidence / 'live-cli-transcripts.txt').write_text('\n\n'.join(transcript))
(evidence / 'live-cli-results.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results, indent=2))
