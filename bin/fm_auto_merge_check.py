#!/usr/bin/env python3
"""Implementation of fm-auto-merge-check.sh; no merge or durable writes."""
import base64
import csv
import fnmatch
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

BIN = Path(__file__).resolve().parent
SHA = re.compile(r"[0-9a-f]{40}")
DENY = BIN/'fm-auto-merge-denylist.globs'
SENSITIVE = re.compile(
    r"secret|credential|password|passwd|token|permission|rights|droits|chmod|chown|"
    r"delet|remov|supprim|force|github|gitlab|remote|publish|publication|"
    r"worker.guard|spawn|teardown|agents\.md|antidrift|wip|config|"
    r"access[_-]?key|api[_-]?key|apikey|authorization|bearer|akia[0-9a-z]{16}|"
    r"private[ _-]?key", re.I)
CHECK_QUERY = '''query($owner:String!,$repo:String!,$number:Int!,$after:String){
 repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid
 statusCheckRollup{contexts(first:100,after:$after){totalCount
 pageInfo{hasNextPage endCursor} nodes{__typename
 ... on CheckRun{id name status conclusion checkSuite{commit{oid}}}
 ... on StatusContext{id context state commit{oid}}}}}}}}'''


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def deny_patterns():
    require(DENY.is_file(), 'auto-merge deny list unavailable')
    values = [line.strip().lower() for line in DENY.read_text().splitlines()]
    patterns = [value for value in values if value and not value.startswith('#')]
    require(patterns, 'auto-merge deny list empty')
    return patterns


def run(args, *, cwd=None, data=None):
    return subprocess.check_output(args, cwd=cwd, input=data, stderr=subprocess.DEVNULL,
                                   timeout=30)


def api(method, path, body=None):
    # Same untruncated base64 JSON envelope as fm_pr_gh_axi_graphql.
    args = ['gh-axi', 'api', method, path, '--full', '--jq', '. | tojson | @base64 | @json']
    if body is not None:
        args += ['--input', '-']
    encoded = run(args, data=json.dumps(body).encode() if body is not None else None)
    value = json.loads(base64.b64decode(encoded.strip(), validate=True))
    require(value is not None and not (isinstance(value, dict) and value.get('errors')),
            'unreadable forge evidence')
    return value


def actor(value):
    require(type(value.get('id')) is int and value['id'] > 0
            and isinstance(value.get('login'), str) and value['login'], 'unreadable identity')
    return value['id'], value['login'].lower()


def checks(project, number, head):
    owner, repo = project.split('/')
    after, seen, nodes, total = None, set(), [], None
    identities = set()
    while True:
        result = api('POST', '/graphql', {'query': CHECK_QUERY,
            'variables': dict(owner=owner, repo=repo, number=int(number), after=after)})
        pr = result['data']['repository']['pullRequest']
        require(pr['headRefOid'] == head, 'checks head drift')
        conn = pr['statusCheckRollup']['contexts']
        count = conn['totalCount']
        require(type(count) is int and count > 0 and (total is None or total == count),
                'checks count unreadable or changed')
        total = count
        batch, info = conn['nodes'], conn['pageInfo']
        require(isinstance(batch, list) and 0 < len(batch) <= 100, 'checks page incomplete')
        nodes.extend(batch)
        require(len(nodes) <= total and type(info['hasNextPage']) is bool, 'checks incomplete')
        for node in batch:
            identity = node['id']
            require(isinstance(identity, str) and identity and identity not in identities,
                    'checks duplicate or unreadable identity')
            identities.add(identity)
            kind = node['__typename']
            if kind == 'CheckRun':
                require(isinstance(node['name'], str) and node['name'] and node['status'] == 'COMPLETED'
                        and node['conclusion'] == 'SUCCESS'
                        and node['checkSuite']['commit']['oid'] == head, 'checks not green at final head')
            elif kind == 'StatusContext':
                require(isinstance(node['context'], str) and node['context'] and node['state'] == 'SUCCESS'
                        and node['commit']['oid'] == head, 'checks status not green at final head')
            else:
                raise ValueError('checks unknown context')
        if not info['hasNextPage']:
            require(len(nodes) == total, 'checks incomplete final page')
            return nodes
        after = info['endCursor']
        require(isinstance(after, str) and after and after not in seen and len(nodes) < total,
                'checks pagination cursor unreadable')
        seen.add(after)


def native_proof(wt, head, branch, url):
    command = ('. "$1"; out=$(fm_nm_run_checked "$2" 20 axi status) || exit; '
               '[ "$(fm_nm_branch_sync_state "$out")" != pipeline_owned ] || exit 1; printf "%s" "$out"')
    try:
        text = run(['bash', '-c', command, '_', str(BIN/'fm-nm-run-lib.sh'), str(wt)]).decode()
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError('native evidence unavailable or pipeline retains custody') from exc
    blocks = re.findall(r'^run:\n((?:[ \t]+[^\n]*(?:\n|$))+)', text, re.M)
    require(len(blocks) == 1, 'native run object missing or ambiguous')
    def scalar(key):
        source = text if key == 'outcome' else blocks[0]
        indent = '' if key == 'outcome' else r'  '
        values = re.findall(r'^' + indent + re.escape(key) + r':[ \t]*(.*?)[ \t]*$', source, re.M)
        require(len(values) == 1, 'native missing or ambiguous ' + key)
        value = values[0]
        return json.loads(value) if value.startswith('"') else value
    run_id = scalar('id')
    status = scalar('status')
    require(bool(run_id) and scalar('branch') == branch and scalar('pr') == url
            and status in ('completed', 'running')
            and scalar('findings') == 'none' and not re.search(r'findings\[', text),
            'native review has missing, open or unfinished evidence')
    native_head = scalar('head')
    require(re.fullmatch(r'[0-9a-f]{7,40}', native_head)
            and git(wt, 'rev-parse', '--verify', native_head + '^{commit}').strip().decode() == head,
            'native final-head mismatch')
    tables = list(re.finditer(r'^\s*steps\[(\d+)\]\{([^}]+)\}:\s*\n', text, re.M))
    require(len(tables) == 1, 'native review ledger missing')
    table = tables[0]
    columns = table[2].split(',')
    rows = []
    for line in text[table.end():].splitlines():
        if not line or not line[0].isspace():
            break
        rows.append(next(csv.reader([line.strip()])))
    require(len(rows) == int(table[1]) and len(set(columns)) == len(columns)
            and all(len(row) == len(columns) for row in rows), 'native review ledger incomplete')
    ledger = [dict(zip(columns, row)) for row in rows]
    reviews = [row for row in ledger if row.get('step') == 'review']
    require(len(reviews) == 1 and reviews[0].get('status') == 'completed'
            and all(row.get('findings') == '0' for row in ledger), 'native review not clean')
    if status == 'completed':
        require(scalar('outcome') in ('passed', 'checks-passed'),
                'native review has missing, open or unfinished evidence')
    else:
        ci = [row for row in ledger if row.get('step') == 'ci']
        require(len(ci) == 1 and ci[0].get('status') == 'running'
                and all(row.get('status') == 'completed' for row in ledger if row.get('step') != 'ci'),
                'native run is not a monitoring-only published CI-ready state')
    return run_id


def git(wt, *args):
    return run(['git', '--literal-pathspecs', '-C', str(wt), *args])


def classify(wt, base, head, files, pr):
    flags = ['--no-ext-diff', '--no-textconv', '--no-renames', '--ignore-submodules=none']
    patterns = deny_patterns()
    raw = git(wt, 'diff', '--raw', '-z', *flags, base, head).split(b'\0')
    require(raw[-1] == b'' and len(raw) % 2 == 1 and len(raw) > 1, 'unreadable real diff')
    records = {}
    for i in range(0, len(raw)-1, 2):
        old_mode, new_mode, _, _, status = raw[i].decode('ascii').split()
        path = raw[i+1].decode('ascii')
        require(old_mode == ':100644' and new_mode == '100644' and status == 'M',
                'unclassified mode, rename, addition or removal')
        require(not any(fnmatch.fnmatchcase(path.lower(), pattern) for pattern in patterns),
                'sensitive path')
        for content in (git(wt, 'cat-file', 'blob', base + ':' + path),
                        git(wt, 'cat-file', 'blob', head + ':' + path)):
            require(not SENSITIVE.search(content.decode('ascii')), 'sensitive content')
        records[path] = git(wt, 'rev-parse', head + ':' + path).strip().decode()
    nums = git(wt, 'diff', '--numstat', '-z', *flags, base, head).split(b'\0')
    stats = {}
    for row in nums[:-1]:
        added, deleted, path = row.decode('ascii').split('\t')
        require(added.isdigit() and deleted.isdigit(), 'binary or unreadable diff')
        stats[path] = (int(added), int(deleted))
    require(set(stats) == set(records), 'incomplete real diff statistics')
    require(sum(d for _, d in stats.values()) <= 50, 'deletion exceeds 50 lines')
    require(len(files) == pr['changed_files'] == len(records), 'incomplete changed-file evidence')
    seen = set()
    for file in files:
        path = file['filename']
        require(path in records and path not in seen and file['status'] == 'modified'
                and not file.get('previous_filename') and file['sha'] == records[path]
                and (file['additions'], file['deletions']) == stats[path],
                'changed-file evidence differs from real diff (including rename source)')
        seen.add(path)
    require(sum(a for a, _ in stats.values()) == pr['additions']
            and sum(d for _, d in stats.values()) == pr['deletions'], 'patch statistics drift')


def main():
    task, url, project, number = sys.argv[1:]
    home = Path(os.environ.get('FM_HOME') or os.environ.get('FM_ROOT_OVERRIDE') or BIN.parent)
    state = Path(os.environ.get('FM_STATE_OVERRIDE') or home/'state')
    meta = state/(task + '.meta')
    info = meta.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'unreadable task metadata')
    snapshot = meta.read_bytes()
    pairs = [line.split('=', 1) for line in snapshot.decode().splitlines() if '=' in line]
    require(len({key for key, _ in pairs}) == len(pairs), 'ambiguous task metadata')
    record = dict(pairs)
    require(record.get('pr') == url and record.get('mode') == 'no-mistakes', 'missing native task binding')
    wt = Path(record['worktree'])
    endpoint = '/repos/' + project + '/pulls/' + number
    pr = api('GET', endpoint)
    require(pr['state'] == 'open' and pr['draft'] is False and pr['mergeable'] is True
            and pr['mergeable_state'] == 'clean', 'PR is not open, non-draft and CLEAN')
    head, base_tip, branch = pr['head']['sha'], pr['base']['sha'], pr['head']['ref']
    require(SHA.fullmatch(head) and SHA.fullmatch(base_tip) and record.get('pr_head') == head,
            'unreadable or unrecorded final head')
    require(git(wt, 'rev-parse', 'HEAD').strip().decode() == head
            and git(wt, 'symbolic-ref', '--short', 'HEAD').strip().decode() == branch,
            'local branch does not bind final head')
    base = git(wt, 'merge-base', base_tip, head).strip().decode()
    require(SHA.fullmatch(base), 'unreadable merge base')
    author, merger = actor(pr['user']), actor(api('GET', '/user'))
    # The guarded merger invokes raw gh, not gh-axi; prove both credential surfaces
    # select the same principal rather than mistaking two tool accounts for actors.
    raw_merger = actor(json.loads(run(['gh', 'api', 'user', '--hostname', 'github.com'])))
    require(merger == raw_merger and author[0] != merger[0] and author[1] != merger[1],
            'author and actual merger identities are same or ambiguous')
    first_checks = checks(project, number, head)
    files, page = [], 1
    require(type(pr['changed_files']) is int and 0 < pr['changed_files'] <= 3000,
            'changed-file inventory unreadable or exceeds forge limit')
    while True:
        batch = api('GET', endpoint + '/files?per_page=100&page=' + str(page))
        require(isinstance(batch, list) and len(batch) <= 100, 'unreadable changed-file page')
        files.extend(batch)
        require(len(files) <= pr['changed_files'], 'changed-file inventory drift')
        if len(batch) < 100:
            break
        page += 1
    classify(wt, base, head, files, pr)
    gate = BIN/'size-gate.sh'
    require(gate.is_file() and os.access(gate, os.X_OK), 'size gate unavailable')
    try:
        output = run([str(gate), base, head], cwd=wt).decode()
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError('size gate refused or unreadable') from exc
    match = re.fullmatch(r'added=(\d+) deleted=(\d+) lines=(\d+) files=(\d+) max_lines=400 max_files=15\n?', output)
    require(match, 'size gate malformed')
    added, deleted, lines, count = map(int, match.groups())
    require(added + deleted == lines and lines <= 400 and count <= 15, 'size gate inconsistent or oversized')
    native = native_proof(wt, head, branch, url)
    require(checks(project, number, head) == first_checks and api('GET', endpoint) == pr,
            'final checks or patch/head drift')
    require(native_proof(wt, head, branch, url) == native and meta.read_bytes() == snapshot,
            'native or task identity drift')
    print(json.dumps(dict(url=url, head=head, base_tip=base_tip, base=base, author_id=author[0],
        merger_id=merger[0], native_run=native, added=added, deleted=deleted, lines=lines, files=count),
        sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, AttributeError, OSError,
            subprocess.SubprocessError) as error:
        print('refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
