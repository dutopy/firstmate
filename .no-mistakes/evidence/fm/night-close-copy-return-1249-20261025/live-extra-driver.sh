#!/usr/bin/env bash
source "$PWD/.local-test-tmp/live-definitions.sh"
set -e
id=task-x1
dir=$(make_case active-lease)
seed_task "$dir" "$id" ship
land_task_branch "$dir" "$id"
printf '%s\n' "$$" > "$dir/home/state/.lock"
FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$FIXTURE_ROOT/bin/fm-lease.sh" claim "$id"
FM_SUPERVISION_ACTOR=main run_close "$dir" "$id" > "$dir/close.out" 2> "$dir/close.err"
[ "$(row_state "$dir" "$id")" = done ]
[ -f "$dir/home/state/$id.meta" ]
[ -f "$dir/home/state/.lease-$id" ]
[ "$(return_count "$dir")" = 0 ]
grep -F 'leased to the branch' "$dir/close.err"
FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_SUPERVISION_ACTOR=branch "$FIXTURE_ROOT/bin/fm-lease.sh" check "$id"
echo 'LIVE: active other-actor lease preserved; close still Done'

dir=$(make_case real-return-retry)
seed_original_task "$dir" "$id" ship "$dir/wt"
land_task_branch "$dir" "$id"
run_close "$dir" "$id" > "$dir/first.out" 2> "$dir/first.err"
[ "$(row_state "$dir" "$id")" = done ]
[ -f "$dir/home/state/$id.meta" ]
grep -F 'is not managed by treehouse' "$dir/first.err"
wt=$(cd "$dir/wt" && pwd -P)
python3 - "$dir/home/state/$id.meta" "$wt" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text('\n'.join('worktree='+sys.argv[2] if line.startswith('worktree=') else line for line in p.read_text().splitlines())+'\n')
PY
run_close "$dir" "$id" > "$dir/second.out" 2> "$dir/second.err"
[ ! -e "$dir/home/state/$id.meta" ]
run_close "$dir" "$id" > "$dir/third.out" 2> "$dir/third.err"
[ "$(return_count "$dir")" = 2 ]
echo 'LIVE: real return failure preserved copy; corrected-path retry returned it; third close did not return twice'
python3 - "$TMP_ROOT" "$EVIDENCE" <<'PY'
import sys,json,os,subprocess
from pathlib import Path
root,out=map(Path,sys.argv[1:]); records={}
for case in sorted(root.iterdir()):
 if not (case/'home').is_dir(): continue
 entries={str(p.relative_to(case)):p.read_text(errors='replace') for p in case.rglob('*') if p.is_file() and (p.suffix in ('.out','.err','.meta') or p.name in ('backlog.md','runtime.log'))}
 status=subprocess.run([os.environ['REAL_TREEHOUSE'],'--root',str(case/'pool'),'status','--json'],cwd=case/'project',env=dict(os.environ,HOME=str(case/'tool-home')),capture_output=True,text=True)
 entries['real-treehouse-status']=status.stdout+status.stderr
 print(case.name,status.stdout.strip())
 records[case.name]=entries
(out/'live-extra-state.json').write_text(json.dumps(records,indent=2))
PY
