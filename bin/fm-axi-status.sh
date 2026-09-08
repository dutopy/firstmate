#!/usr/bin/env bash
# fm-axi-status.sh - read live aggregate status and write validated AXI events.
#
# Usage:
#   fm-axi-status.sh [--full] [--width N]
#   fm-axi-status.sh write [--update] --task-id ID --state STATE [fields]
#   fm-axi-status.sh validate [FILE]
#
# The versioned state/axi-status.v1.log file is immutable logical event history:
# each successful new write atomically republishes the prior bytes plus one full
# validated event. The reader projects the last event per task, then reconciles
# current state through fm-crew-state.sh. Legacy state/<task>.status files are
# never read as current truth and are never changed by this command.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
JOURNAL="${FM_AXI_STATUS_LEDGER:-$STATE/axi-status.v1.log}"
export FM_AXI_SCRIPT_DIR="$SCRIPT_DIR"
export FM_AXI_STATE_DIR="$STATE"
export FM_AXI_STATUS_JOURNAL="$JOURNAL"

exec python3 - "$@" <<'PY'
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse

args = sys.argv[1:]
state_dir = os.environ['FM_AXI_STATE_DIR']
journal = os.environ['FM_AXI_STATUS_JOURNAL']
lock_path = journal + '.lock'
fields = ('task_id', 'state', 'kind', 'path', 'pr', 'capability',
          'error_code', 'error_message', 'merge_state', 'event_id', 'updated_at')
allowed = set(fields)
states = {'working', 'parked', 'done', 'blocked', 'paused', 'failed', 'unknown'}
merge_states = {'open', 'merged', 'unknown'}
task_re = re.compile(r'^[A-Za-z][A-Za-z0-9_.-]*$')


def fail(code, message, field=None, status=2):
    print('error:', file=sys.stderr)
    print('  code: ' + code, file=sys.stderr)
    if field:
        print('  field: ' + field, file=sys.stderr)
    print('  message: ' + json.dumps(message, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(status)


def encode(value):
    return urllib.parse.quote(str(value), safe='/._-:')


def decode(value):
    if re.search(r'%(?![0-9A-Fa-f]{2})', value):
        fail('INVALID_ENCODING', 'invalid percent triplet', 'record')
    try:
        return urllib.parse.unquote_to_bytes(value).decode('utf-8', errors='strict')
    except UnicodeDecodeError:
        fail('INVALID_ENCODING', 'percent encoding is not valid UTF-8', 'record')


def validate(row):
    if not row.get('task_id'):
        fail('MISSING_TASK_ID', 'task_id is required', 'task_id')
    if not task_re.fullmatch(row['task_id']):
        fail('INVALID_TASK_ID', 'task_id must be a portable identifier', 'task_id')
    if not row.get('state'):
        fail('MISSING_STATE', 'state is required', 'state')
    if row['state'] not in states:
        fail('INVALID_STATE', 'unsupported state', 'state')
    kind = row.get('kind', 'event')
    if kind not in {'event', 'delivery'}:
        fail('INVALID_KIND', 'kind must be event or delivery', 'kind')
    if kind == 'delivery' and not (row.get('path') or row.get('pr')):
        fail('MISSING_DELIVERY_REFERENCE', 'delivery requires path or pr', 'path|pr')
    if row.get('pr') and not re.fullmatch(r'https?://[^\s]+', row['pr']):
        fail('INVALID_PR', 'pr must be an absolute HTTP(S) URL', 'pr')
    if row.get('merge_state') and row['merge_state'] not in merge_states:
        fail('INVALID_MERGE_STATE', 'merge_state must be open, merged, or unknown', 'merge_state')
    if row.get('merge_state') in {'open', 'merged'} and not row.get('pr'):
        fail('MISSING_MERGE_IDENTITY', 'open or merged requires pr', 'pr')
    return row


def parse_record(line, source='record'):
    line = line.rstrip('\n')
    prefix = 'axi-status.v1 '
    if not line.startswith(prefix):
        fail('INVALID_RECORD_PREFIX', 'expected axi-status.v1 prefix', source)
    row = {}
    for item in line[len(prefix):].split(' '):
        if '=' not in item:
            fail('INVALID_FIELD', 'field lacks equals separator', source)
        key, value = item.split('=', 1)
        if key not in allowed:
            fail('UNKNOWN_FIELD', 'unsupported record field', key)
        if key in row:
            fail('DUPLICATE_FIELD', 'record field appears more than once', key)
        if not value:
            fail('EMPTY_FIELD', 'record fields cannot be empty', key)
        row[key] = decode(value)
    return validate(row)


def format_record(row):
    return ' '.join(['axi-status.v1'] + [key + '=' + encode(row[key])
                    for key in fields if row.get(key, '') != '']) + '\n'


def read_records(path):
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding='utf-8', errors='strict') as handle:
            return [parse_record(line, '%s:%d' % (path, number))
                    for number, line in enumerate(handle, 1) if line.strip()]
    except UnicodeDecodeError:
        fail('INVALID_ENCODING', 'record file is not valid UTF-8', path)
    except OSError as exc:
        fail('IO_ERROR', str(exc), path, 1)


def read_text(path):
    if not os.path.exists(path):
        return ''
    try:
        with open(path, encoding='utf-8', errors='strict') as handle:
            return handle.read()
    except UnicodeDecodeError:
        fail('INVALID_ENCODING', 'record file is not valid UTF-8', path)
    except OSError as exc:
        fail('IO_ERROR', str(exc), path, 1)


def atomic_publish(path, text):
    directory = os.path.dirname(path) or '.'
    os.makedirs(directory, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.axi-status.', dir=directory)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def usage():
    print('usage: fm-axi-status.sh [--full] [--width N]')
    print('       fm-axi-status.sh write [--update] --task-id ID --state STATE [options]')
    print('       fm-axi-status.sh validate [FILE]')
    print('run `fm-axi-status.sh write --help` or `validate --help` for subcommand details.')


def usage_write():
    print('usage: fm-axi-status.sh write [--update] --task-id ID --state STATE [options]')
    print('states: working|parked|done|blocked|paused|failed|unknown')
    print('writer options: --kind event|delivery --path PATH --pr URL')
    print('                --capability NAME --error-code CODE --error-message TEXT')
    print('                --merge-state open|merged|unknown --event-id ID')
    print('delivery requires --path or --pr; --event-id identifies an idempotent retry.')


def usage_validate():
    print('usage: fm-axi-status.sh validate [FILE]')
    print('validates and canonicalizes every axi-status.v1 record; default FILE is the live journal.')


def take_value(index, flag):
    if index + 1 >= len(args) or args[index + 1] == '' or args[index + 1].startswith('--'):
        fail('MISSING_OPTION_VALUE', flag + ' requires a non-empty value', flag[2:])
    return args[index + 1], index + 2


def semantic(row):
    return {key: value for key, value in row.items() if key != 'updated_at'}


def merge_identity(url):
    match = re.fullmatch(r'https://github\.com/([^/]+)/([^/]+)/pull/([1-9][0-9]*)', url or '')
    if match:
        return ('github', 'github.com', match.group(1) + '/' + match.group(2), match.group(3))
    match = re.fullmatch(r'https://([^/]+)/(.+)/-/merge_requests/([1-9][0-9]*)', url or '')
    if match:
        return ('gitlab', match.group(1), match.group(2), match.group(3))
    return None


def merge_marker_matches(task, pr):
    marker = os.path.join(state_dir, task + '.pr-poll-merge-notified')
    if not pr or not os.path.isfile(marker):
        return False
    try:
        with open(marker, encoding='utf-8', errors='strict') as handle:
            values = [line.rstrip('\n') for line in handle]
    except (OSError, UnicodeError):
        return False
    return (len(values) == 5 and values[0] == 'fm-pr-poll-merge-notified-v1'
            and merge_identity(pr) == tuple(values[1:]))


def wrap(label, value, width):
    text = label + '=' + value
    if len(text) <= width:
        return [text]
    room = width - 2
    return [label + '='] + ['  ' + value[offset:offset + room]
                            for offset in range(0, len(value), room)]


def compact(row, width):
    summary = ' | '.join((row['task_id'], row.get('state', 'unknown'), row.get('kind', 'event')))
    if len(summary) <= width:
        lines = [summary]
    else:
        lines = (wrap('task', row['task_id'], width)
                 + wrap('state', row.get('state', 'unknown'), width)
                 + wrap('kind', row.get('kind', 'event'), width))
    for label, key in (('capability', 'capability'), ('error', 'error_code'), ('merge', 'merge_state')):
        if row.get(key):
            lines.extend(wrap(label, row[key], width))
    if row.get('error_message'):
        lines.extend(wrap('error_message', row['error_message'], width))
    if row.get('path') or row.get('pr'):
        lines.extend(('details=omitted;', 'rerun --full', 'for path/pr'))
    return lines


if args in (['--help'], ['-h']):
    usage()
    raise SystemExit(0)

if args and args[0] == 'validate':
    if args[1:] in (['--help'], ['-h']):
        usage_validate()
        raise SystemExit(0)
    if len(args) > 2 or (len(args) == 2 and args[1].startswith('-')):
        fail('UNKNOWN_OPTION', 'validate accepts at most one file', 'option')
    path = args[1] if len(args) == 2 else journal
    if not os.path.isfile(path):
        fail('NOT_FOUND', 'record file not found', path, 1)
    for record in read_records(path):
        print(format_record(record), end='')
    raise SystemExit(0)

if args and args[0] == 'write':
    if args[1:] in (['--help'], ['-h']):
        usage_write()
        raise SystemExit(0)
    values = {}
    update = False
    option_map = {
        '--task-id': 'task_id', '--state': 'state', '--kind': 'kind', '--path': 'path',
        '--pr': 'pr', '--capability': 'capability', '--error-code': 'error_code',
        '--error-message': 'error_message', '--merge-state': 'merge_state', '--event-id': 'event_id'
    }
    index = 1
    while index < len(args):
        flag = args[index]
        if flag == '--update':
            if update:
                fail('DUPLICATE_OPTION', '--update supplied twice', 'update')
            update = True
            index += 1
            continue
        if flag not in option_map:
            fail('UNKNOWN_OPTION', 'unsupported writer option', flag)
        key = option_map[flag]
        if key in values:
            fail('DUPLICATE_OPTION', 'option supplied twice', key)
        values[key], index = take_value(index, flag)
    request = {'task_id': values.get('task_id', ''), 'state': values.get('state', '')}
    request.update({key: value for key, value in values.items() if key not in request})
    # Validate the explicit request before any retry shortcut. An update may need
    # retained delivery fields, so only its required identifiers are checked here.
    if update:
        if not request['task_id']:
            fail('MISSING_TASK_ID', 'task_id is required', 'task_id')
        if not task_re.fullmatch(request['task_id']):
            fail('INVALID_TASK_ID', 'task_id must be a portable identifier', 'task_id')
        if not request['state']:
            fail('MISSING_STATE', 'state is required', 'state')
        if request['state'] not in states:
            fail('INVALID_STATE', 'unsupported state', 'state')
        if request.get('merge_state') and request['merge_state'] not in merge_states:
            fail('INVALID_MERGE_STATE', 'merge_state must be open, merged, or unknown', 'merge_state')
    else:
        validate(request)
    try:
        os.makedirs(os.path.dirname(lock_path) or '.', exist_ok=True)
        with open(lock_path, 'a+', encoding='utf-8') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            existing_text = read_text(journal)
            records = [parse_record(line, journal) for line in existing_text.splitlines()
                       if line.strip()]
            latest = next((row for row in reversed(records)
                           if row['task_id'] == request['task_id']), None)
            candidate = dict(latest or {}) if update else {}
            if update and 'event_id' not in request:
                candidate.pop('event_id', None)
            candidate.update(request)
            validate(candidate)
            event_id = candidate.get('event_id')
            if event_id:
                prior = next((row for row in records if row.get('event_id') == event_id), None)
                if prior:
                    if semantic(prior) == semantic(candidate):
                        print('unchanged')
                        raise SystemExit(0)
                    fail('EVENT_ID_COLLISION', 'event_id already identifies a different event', 'event_id')
            if latest and semantic(latest) == semantic(candidate):
                print('unchanged')
                raise SystemExit(0)
            candidate['updated_at'] = datetime.datetime.now(datetime.timezone.utc).replace(
                microsecond=0).isoformat().replace('+00:00', 'Z')
            separator = '\n' if existing_text and not existing_text.endswith('\n') else ''
            atomic_publish(journal, existing_text + separator + format_record(candidate))
    except OSError as exc:
        fail('IO_ERROR', str(exc), journal, 1)
    print('written task_id=' + candidate['task_id'])
    raise SystemExit(0)

if args and args[0] not in {'--full', '--width'}:
    fail('UNKNOWN_COMMAND', 'unknown command', args[0])

full = False
width = 100
index = 0
seen = set()
while index < len(args):
    flag = args[index]
    if flag == '--full':
        if flag in seen:
            fail('DUPLICATE_OPTION', '--full supplied twice', 'full')
        full = True
        seen.add(flag)
        index += 1
    elif flag == '--width':
        if flag in seen:
            fail('DUPLICATE_OPTION', '--width supplied twice', 'width')
        raw, index = take_value(index, flag)
        try:
            width = int(raw)
        except ValueError:
            fail('INVALID_WIDTH', 'width must be an integer', 'width')
        if width < 20:
            fail('INVALID_WIDTH', 'width must be at least 20', 'width')
        seen.add(flag)
    else:
        fail('UNKNOWN_OPTION', 'unsupported reader option', flag)

records = read_records(journal)
latest = {}
for record in records:
    latest[record['task_id']] = record
tasks = set(latest)
if os.path.isdir(state_dir):
    tasks.update(name[:-5] for name in os.listdir(state_dir) if name.endswith('.meta'))
script_dir = os.environ['FM_AXI_SCRIPT_DIR']
crew_state = os.environ.get('FM_AXI_CREW_STATE_BIN', os.path.join(script_dir, 'fm-crew-state.sh'))
for task in sorted(tasks):
    stored = dict(latest.get(task, {'task_id': task, 'kind': 'event'}))
    asserted_pr = stored.get('pr')
    metadata_path = os.path.join(state_dir, task + '.meta')
    metadata = {}
    if os.path.isfile(metadata_path):
        try:
            with open(metadata_path, encoding='utf-8', errors='strict') as handle:
                for line in handle:
                    if '=' in line:
                        key, value = line.rstrip('\n').split('=', 1)
                        metadata[key] = value
        except (OSError, UnicodeError):
            metadata = {}
    for key in ('path', 'pr'):
        if key in metadata:
            if metadata[key]:
                stored[key] = metadata[key]
            else:
                stored.pop(key, None)
    if os.path.isfile(metadata_path):
        try:
            result = subprocess.run(
                [crew_state, task], env=dict(os.environ, FM_STATE_OVERRIDE=state_dir),
                text=True, capture_output=True, timeout=10, check=False)
            match = re.search(r'^state: ([^ ]+)', result.stdout, re.MULTILINE)
            stored['state'] = match.group(1) if match else 'unknown'
        except (OSError, subprocess.SubprocessError):
            stored['state'] = 'unknown'
    else:
        stored['state'] = 'unknown'
    current_pr = stored.get('pr')
    if merge_marker_matches(task, current_pr):
        stored['merge_state'] = 'merged'
    elif current_pr and asserted_pr == current_pr and stored.get('merge_state') in merge_states:
        # The controlled writer's explicit merge field is identity-bound to the
        # same PR. Metadata replacement/clearing invalidates that assertion.
        stored['merge_state'] = stored.get('merge_state', 'unknown')
    else:
        stored['merge_state'] = 'unknown'
    if full:
        parts = [task, stored.get('state', 'unknown'), stored.get('kind', 'event')]
        if stored.get('capability'):
            parts.append('capability=' + stored['capability'])
        if stored.get('error_code'):
            parts.append('error=' + stored['error_code'])
        if stored.get('path'):
            parts.append('path=' + stored['path'])
        if stored.get('pr'):
            parts.append('pr=' + stored['pr'])
        if stored.get('error_message'):
            parts.append('error_message=' + stored['error_message'])
        parts.append('merge_state=' + stored['merge_state'])
        print(' | '.join(parts))
    else:
        print('\n'.join(compact(stored, width)))
if not tasks:
    print('no AXI records')
PY
