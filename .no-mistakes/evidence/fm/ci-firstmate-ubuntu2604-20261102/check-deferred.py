import json, os, pathlib, subprocess
root = pathlib.Path.cwd()
home = root / '.local-test/deferred-home'
(home / 'config').mkdir(parents=True, exist_ok=True)
(home / 'state').mkdir(exist_ok=True)
(home / 'bin').mkdir(exist_ok=True)
(home / 'AGENTS.md').write_text('# disposable home\n')
(home / 'config/deferred-questions').touch()
subprocess.run(['git', '-C', str(home), 'init', '-q'], check=True)
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
env.pop('FM_DEFERRED_QUESTIONS', None)
ask = json.dumps({'session_id': 'test-local', 'tool_name': 'AskUserQuestion', 'tool_use_id': 'toolu-local', 'tool_input': {'questions': [{'question': 'Merge test PR?', 'header': 'Merge', 'options': [{'label': 'Yes', 'description': 'y'}, {'label': 'No', 'description': 'n'}], 'multiSelect': False}]}}).encode()
cmd = [str(root / 'bin/fm-deferred-question.sh'), 'pretool', '--claude']
store = home / 'state/deferred-questions'
def records():
    return {p.name: p.read_bytes() for p in store.glob('*.json')}
def fail_delivery(mode):
    if mode == 'closed':
        def close_stdout():
            os.close(1)
        result = subprocess.run(cmd, input=ask, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, preexec_fn=close_stdout)
    else:
        r, w = os.pipe()
        os.close(r)
        try:
            result = subprocess.run(cmd, input=ask, stdout=w, stderr=subprocess.PIPE, env=env)
        finally:
            os.close(w)
    assert result.returncode == 0, result.stderr
    print(f'{mode} delivery: exit={result.returncode}, stderr={result.stderr.decode().strip()!r}')
for mode in ['closed', 'broken-pipe']:
    for p in store.glob('*.json'):
        p.unlink()
    fail_delivery(mode)
    assert not records(), records()
    print(f'{mode} new-record rollback: pending=0')
    result = subprocess.run(cmd, input=ask, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=True)
    output = json.loads(result.stdout)
    assert output['hookSpecificOutput']['permissionDecision'] == 'allow'
    assert len(records()) == 1
    print('successful delivery output:', json.dumps(output, sort_keys=True))
    before = records()
    fail_delivery(mode)
    assert records() == before
    print(f'{mode} retry: pending=1; existing record bytes unchanged')
print('Deferred-question public CLI: all delivery and persistence assertions satisfied.')
