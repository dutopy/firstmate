#!/usr/bin/env bash
set -u
source "$PWD/.local-test-tmp/fixture-functions.sh"
REAL_TREEHOUSE=$(command -v treehouse)
export REAL_TREEHOUSE
# Retain the existing disposable setup; replace only the pool double with the real tool.
eval "$(declare -f make_case | sed '1s/make_case/make_original_case/')"
make_case() {
  local dir wt
  dir=$(make_original_case "$1") || return
  git -C "$dir/project" worktree remove "$dir/wt" || return
  git -C "$dir/project" branch -D fm/task-x1 >/dev/null || return
  mkdir -p "$dir/tool-home"
  wt=$(cd "$dir/project" && HOME="$dir/tool-home" "$REAL_TREEHOUSE" --root "$dir/pool" get --lease --no-fetch --branch fm/task-x1) || return
  ln -s "$wt" "$dir/wt"
  ln -s "$(dirname "$wt")" "$dir/pool/1"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "$FM_RUNTIME_LOG"
printf ' <%s>' "$@" >> "$FM_RUNTIME_LOG"
printf '\n' >> "$FM_RUNTIME_LOG"
export HOME="$(dirname "$FM_RUNTIME_LOG")/tool-home"
exec "$REAL_TREEHOUSE" "$@"
SH
  chmod +x "$dir/fakebin/treehouse"
  printf '%s\n' "$dir"
}
eval "$(declare -f seed_task | sed '1s/seed_task/seed_original_task/')"
seed_task() {
  local wt
  wt=$(cd "${4:-$1/wt}" && pwd -P)
  seed_original_task "$1" "$2" "$3" "$wt" "${5:-$1/project}"
}
eval "$(declare -f run_close | sed '1s/run_close/run_original_close/')"
run_close() {
  # A real shared pool anchors allocation locks at the root home's state/.
  mkdir -p "$1/home/state"
  run_original_close "$@"
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  python3 - "$TMP_ROOT" "$EVIDENCE" <<'PY'
import sys,json
from pathlib import Path
root,out=map(Path,sys.argv[1:])
records={str(p.relative_to(root)):p.read_text(errors='replace') for p in root.rglob('*') if p.is_file() and (p.suffix in ('.out','.err') or p.name in ('runtime.log','treehouse-state.json','err','out'))}
(out/'live-failure-diagnostics.json').write_text(json.dumps(records,indent=2))
for k,v in records.items():
    if k.endswith(('.err','/err')): print(k,v)
PY
  exit 1
}
# Run existing executable-interface assertions against actual pool slots.
test_close_returns_clean_landed_copy
test_state_override_returns_copy
test_close_help_never_cleans_up
test_equivalent_backlog_path_returns_copy trailing-slash
test_equivalent_backlog_path_returns_copy symlink
test_equivalent_backlog_path_returns_copy dot-segments
test_after_close_preserves_completion pr
test_after_close_preserves_completion report
test_after_close_preserves_completion note
test_completed_scout_copy_safety dirty
test_completed_scout_copy_safety unlanded
test_completed_scout_copy_safety landed
test_dirty_copy_is_preserved
test_unlanded_copy_is_preserved
test_reassigned_slot_is_preserved
test_repeated_close_converges
test_after_close_refuses_an_open_row
test_secondmate_record_is_never_torn_down
test_foreign_backlog_close_preserves_copy
test_concurrent_close_converges
test_recovery_marker_is_preserved
python3 - "$TMP_ROOT" "$EVIDENCE" <<'PY'
import sys,json,subprocess,os
from pathlib import Path
root,out=map(Path,sys.argv[1:])
records={}
for case in sorted(root.iterdir()):
    if not (case/'home').is_dir(): continue
    entries={str(p.relative_to(case)):p.read_text(errors='replace') for p in case.rglob('*') if p.is_file() and (p.suffix in ('.out','.err') or p.name in ('backlog.md','runtime.log','treehouse-state.json'))}
    env=dict(os.environ, HOME=str(case/'tool-home'))
    status=subprocess.run([os.environ['REAL_TREEHOUSE'],'--root',str(case/'pool'),'status','--json'],cwd=case/'project',env=env,text=True,capture_output=True)
    entries['real-treehouse-status']=status.stdout+status.stderr
    print(case.name, status.stdout.strip())
    records[case.name]=entries
(out/'live-cli-state.json').write_text(json.dumps(records,indent=2))
PY
