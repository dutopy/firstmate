import json, os, pathlib, subprocess
root = pathlib.Path.cwd()
config = root / '.local-test/discord-config.json'
data = json.loads(config.read_text())
data['live']['polling'] = True
config.write_text(json.dumps(data))
home = root / '.local-test/discord-regression'
home.mkdir(exist_ok=True)
env = dict(os.environ, FM_HOME=str(home))
python = str(root / '.local-test/python/cpython-3.14.3-macos-x86_64-none/bin/python3.14')
for label, script in [('before', root / '.local-test/discord-before.py'), ('after', root / 'bin/fm_discord_workspace_lib.py')]:
    result = subprocess.run([python, str(script), 'procevent', str(root / 'bin'), 'source', '--config', str(config)], env=env, capture_output=True, text=True)
    print(f'{label}: exit={result.returncode}\n{result.stdout}{result.stderr}')
    if label == 'before':
        assert result.returncode == 1
        assert "has no attribute 'util'" in result.stderr
    else:
        assert 'AttributeError' not in result.stderr
        assert 'secret' in result.stderr.lower() or 'secret' in result.stdout.lower()
print('Python 3.14 regression reproduced before the fix; fixed source loads the live module and reaches its actionable secret-file guard.')
