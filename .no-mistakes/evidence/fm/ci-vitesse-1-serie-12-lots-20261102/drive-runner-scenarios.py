import collections, json, os, pathlib, shutil, subprocess
root = pathlib.Path.cwd()
runner = root / 'bin/fm-test-run.sh'
env = dict(os.environ, TMPDIR=str(root / '.test-phase/tmp'), FM_HOME=str(root / '.test-phase/home'))
def call(args, expected=0):
    p = subprocess.run([str(x) for x in args], env=env, text=True, capture_output=True)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p
lanes = call([runner, '--list-lanes']).stdout.splitlines()
serial = call([runner, '--list', '--lane', 'portable-serial']).stdout.splitlines()
workflow = json.loads(call(['ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]).fetch("jobs").fetch("tests-portable-serial"))', '.github/workflows/ci.yml']).stdout)
shards = workflow['strategy']['matrix']['shard']
assert shards == list(range(1, 13))
assert workflow['timeout-minutes'] == 25
step = next(s for s in workflow['steps'] if 'FM_SERIAL_LANE' in s.get('env', {}))
pattern = step['env']['FM_SERIAL_LANE']
assert pattern == 'portable-serial-${{ matrix.shard }}of${{ strategy.job-total }}'
combined = []
for shard in shards:
    lane = pattern.replace('${{ matrix.shard }}', str(shard)).replace('${{ strategy.job-total }}', str(len(shards)))
    assert lane in lanes
    members = call([runner, '--list', '--lane', lane]).stdout.splitlines()
    assert members
    assert members == call([runner, '--list', '--lane', lane]).stdout.splitlines()
    combined.extend(members)
    print(json.dumps({'lane':lane, 'count':len(members), 'members':members}))
assert len(serial) == 226
assert collections.Counter(combined) == collections.Counter(serial)
assert len(combined) == len(set(combined))
print('Exact partition: all 226 serial scripts occur once across 12 nonempty, repeatable workflow-derived lanes.')
print('Workflow semantic model: serial timeout 25 minutes; lane denominator derives from strategy.job-total.')
for lane in ['portable-serial-1of5', 'portable-serial-0of12', 'portable-serial-13of12', 'portable-serial-1']:
    p = call([runner, '--list', '--lane', lane], 2)
    print(json.dumps({'rejected_lane':lane, 'exit':p.returncode, 'stderr':p.stderr.strip()}))
fixture = root / '.test-phase/fixture'
(fixture/'bin').mkdir(parents=True)
(fixture/'tests').mkdir()
shutil.copy2(runner, fixture/'bin/fm-test-run.sh')
shutil.copy2(root/'tests/git-config-helpers.sh', fixture/'tests/git-config-helpers.sh')
script = fixture/'tests/fm-afk-inject-e2e.test.sh'
script.write_text('#!/usr/bin/env bash\nprintf "executed unproven disposable script\\n" > ran\necho "ok - disposable script executed"\n')
script.chmod(0o755)
r = fixture/'bin/fm-test-run.sh'
assert call([r, '--list', '--lane', 'portable-serial-1of12']).stdout.strip() == 'tests/fm-afk-inject-e2e.test.sh'
for selection in [['--lane','portable-serial'], ['tests/fm-afk-inject-e2e.test.sh'], ['--lane','portable-serial-1of12']]:
    p = call([r, '--jobs', '2', *selection], 2)
    assert 'not in the proven-isolated set' in p.stderr
    assert not (fixture/'ran').exists()
    print(json.dumps({'selection':selection,'jobs':2,'exit':2,'stderr':p.stderr.strip(),'executed':False}))
p = call([r, '--lane', 'portable-serial-1of12'])
assert (fixture/'ran').read_text() == 'executed unproven disposable script\n'
print(p.stdout)
print('Same unproven fixture executes serially, but all three concurrent selections refuse before side effects.')
