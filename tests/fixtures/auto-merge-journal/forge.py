#!/usr/bin/env python3
"""Read versioned response data; never construct encoded payloads."""
import json
import os
from pathlib import Path
import sys

world = Path(os.environ['FM_JOURNAL_WORLD'])
fixtures = Path(os.environ['FM_JOURNAL_FIXTURES'])
args = sys.argv[1:]
name = Path(sys.argv[0]).name
mode = (world / 'mode').read_text().strip()
accepted = (world / 'accepted').exists()
with (world / 'calls').open('a') as log:
    log.write(json.dumps([name] + args) + '\n')

def fixture_path(name):
    path = fixtures / name
    if mode == 'zero-files':
        alt = fixtures / name.replace('.', '-zero.', 1)
        if alt.is_file():
            return alt
    return path

def emit(key):
    print(fixture_path(key + '.b64').read_text().strip())

if name == 'no-mistakes':
    print(fixture_path('native.toon').read_text())
elif name == 'gh':
    if args == ['api', 'user', '--hostname', 'github.com']:
        print((fixtures / 'actor.json').read_text())
    elif args[:3] == ['pr', 'merge', '7']:
        if mode == 'failed':
            sys.exit(1)
        expected = fixture_path('head.sha').read_text().strip()
        if args[args.index('--match-head-commit') + 1] != expected:
            sys.exit(2)
        (world / 'accepted').write_text('yes')
        print('request accepted')
    else:
        sys.exit(90)
elif args[:3] == ['api', 'POST', '/graphql']:
    query = json.load(sys.stdin)['query']
    if 'pageInfo' in query:
        emit('checks-red' if mode == 'ineligible' else 'checks')
    elif 'statusCheckRollup' in args[args.index('--jq') + 1]:
        emit('mergeable')
    else:
        if accepted and mode == 'unreadable':
            sys.exit(1)
        emit('queued' if mode == 'queued' else 'merged' if accepted else 'open')
elif args[:2] == ['api', 'GET']:
    endpoint = args[2]
    if endpoint == '/user':
        emit('actor')
    elif endpoint.endswith('/files?per_page=100&page=1'):
        emit('files')
    elif endpoint.endswith('/rules/branches/main'):
        emit('rules')
    elif endpoint == '/repos/example/repo/pulls/7':
        emit('landed-wrong' if mode == 'wrong-head' and accepted else
             'landed' if accepted and mode != 'queued' else 'pr')
    else:
        sys.exit(91)
elif args[:2] == ['api', '/repos/example/repo/pulls/7']:
    print(fixture_path('head.sha').read_text().strip())
else:
    sys.exit(92)
