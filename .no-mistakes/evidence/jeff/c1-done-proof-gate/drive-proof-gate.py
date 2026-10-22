#!/usr/bin/env python3
"""Drive real Firstmate CLIs against disposable records; preserve inputs and output."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('/Users/pierre/.no-mistakes/evidence/01M5JPEAWA3T74QGH46PH6WQMV')
work = Path(tempfile.mkdtemp(prefix='proof-live-', dir=ROOT / '.local-test'))
log = []
results = []
base = {
    'root_cause': 'daemon restart concealed sustained CPU use',
    'regression_test': 'isolated daemon CPU reproduction',
    'retest': 'CPU remained below the specified limit after the fix',
    'authoritative_state': 'process table re-read after the change',
    'artifact_or_scope': 'disposable local daemon instance',
    'rollback': 'git revert 0123456789abcdef',
}
checker = ROOT / 'bin/fm-done-proof.sh'
env = os.environ.copy()
for key in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_ROOT_OVERRIDE', 'FM_CAPTAIN_RE', 'FM_CLASSIFY_PAUSED_VERB'):
    env.pop(key, None)
env['FM_HOME'] = str(work / 'home')
env['TMPDIR'] = str(ROOT / '.local-test/tmp')

def record(path, content):
    path.write_bytes(content.encode())
    log.append(f'INPUT {path.relative_to(work)}: {content!r}')
    return path

def packet(values, suffix='\n'):
    return ''.join(f'{key}: {value}{suffix}' for key, value in values.items())

def run(args, expected, cwd=ROOT):
    proc = subprocess.run([str(x) for x in args], cwd=cwd, env=env, text=True, capture_output=True)
    log.append(f'$ (cwd={cwd}) {list(map(str, args))!r}\nexit={proc.returncode}\nstdout={proc.stdout.rstrip()!r}\nstderr={proc.stderr.rstrip()!r}')
    if proc.returncode != expected:
        raise AssertionError(f'expected exit {expected}, got {proc.returncode}')
    return proc.stdout

def scenario(name, body):
    log.append('\n## ' + name)
    start = len(log)
    try:
        body()
        results.append({'name': name, 'result': 'pass', 'live': True})
    except Exception as exc:
        log.append('FAILURE: ' + str(exc))
        results.append({'name': name, 'result': 'fail', 'live': len(log) > start, 'reason': str(exc)})

try:
    complete = record(work / 'complete.proof', packet(base))
    done = record(work / 'done.status', 'working: fixing\ndone: PR https://example.com/pr/1\n')
    absent = work / 'absent.proof'
    def complete_case():
        for ending in ('\n', '\r\n'):
            proof = record(work / 'complete-input.proof', packet(base, ending))
            run([checker, proof], 0)
            run([checker, '--status', done, proof], 0)
    scenario('Accept substantive LF and CRLF proof packets directly and for a done claim', complete_case)

    def invalid_fields():
        for key in base:
            missing = dict(base)
            del missing[key]
            proof = record(work / 'invalid.proof', packet(missing))
            for prefix in ([], ['--status', done]):
                run([checker, *prefix, proof], 1)
            for value in ('unknown', 'n/a', 'none', 'na', '?', 'TODO later', 'TBD later'):
                for ending in (' \t\n', '\r\n'):
                    invalid = dict(base, **{key: '\t' + value})
                    proof = record(work / 'invalid.proof', packet(invalid, ending))
                    for prefix in ([], ['--status', done]):
                        run([checker, *prefix, proof], 1)
    scenario('Refuse each missing field and whitespace-padded placeholder through both CLI forms', invalid_fields)

    def workaround():
        for status in ('workaround', 'WORKAROUND', '\tWorkaround \t', 'workaround\r'):
            proof = record(work / 'workaround.proof', packet(dict(base, status=status)))
            for prefix in ([], ['--status', done]):
                run([checker, *prefix, proof], 1)
    scenario('Refuse workaround completion including mixed case, trailing spaces, and carriage returns', workaround)

    def non_done():
        for content in ('', 'working: fixing\n', 'done: previous completion\nworking: follow-up\n checks green\n', 'paused: waiting for upstream\n'):
            status = record(work / 'non-done.status', content)
            run([checker, '--status', status, absent], 0)
    scenario('Allow unfinished work without proof and honor a later working event', non_done)

    def grammar():
        workaround = record(work / 'workaround.proof', packet(dict(base, status='workaround')))
        for declaration in ('done: PR https://example.com/pr/1', 'done [key=fix]: ready', 'done: [key=fix] ready', ' \tdone: ready', 'done [corr=0123456789abcdef] [key=fix]: ready', 'done corr=0123456789abcdef [key=fix]: ready'):
            for continuation in (' checks green\n', ' verification finished\n checks green\n\n', ''.join(' continuation text\n' for _ in range(205))):
                status = record(work / 'event.status', 'working: fixing\n' + declaration + '\n' + continuation)
                run([checker, '--status', status, absent], 1)
                run([checker, '--status', status, workaround], 1)
                run([checker, '--status', status, complete], 0)
    scenario('Require proof for keyed and indented done declarations despite continuation prose and long tails', grammar)

    def external():
        install = work / 'firstmate scripts'
        install.mkdir()
        for name in ('fm-brief.sh', 'fm-dod-lib.sh', 'fm-marker-lib.sh', 'fm-operational-input.sh', 'fm-classify-lib.sh', 'fm-timeout-lib.sh', 'fm-done-proof.sh'):
            shutil.copy2(ROOT / 'bin' / name, install / name)
        worker = work / 'unrelated worker'
        worker.mkdir()
        for mode in ('direct-PR', 'local-only', 'no-mistakes'):
            run([install / 'fm-brief.sh', mode, 'disposable-project', '--mode', mode], 0, worker)
            brief = (work / 'home/data' / mode / 'brief.md').read_text()
            (EVIDENCE / f'{mode}-generated-brief.md').write_text(brief)
            line = next(line for line in brief.splitlines() if line.startswith("Before any 'done:'"))
            log.append('GENERATED INSTRUCTION: ' + line)
            command = re.search(r' and make (.*) <packet> pass;', line).group(1)
            run(['bash', '-c', command + ' "$1"', '_', complete], 0, worker)
            proof = record(work / 'workaround.proof', packet(dict(base, status='workaround')))
            run(['bash', '-c', command + ' "$1"', '_', proof], 1, worker)
    scenario('Run every delivery mode’s generated proof command from another project with spaces in the installation path', external)
finally:
    shutil.rmtree(work)
    (EVIDENCE / 'proof-gate-cli-transcript.txt').write_text('\n'.join(log) + '\n')
    (EVIDENCE / 'proof-gate-scenario-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
raise SystemExit(any(result['result'] != 'pass' for result in results))
