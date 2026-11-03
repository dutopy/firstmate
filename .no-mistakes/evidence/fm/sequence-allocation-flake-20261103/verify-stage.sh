#!/usr/bin/env bash
set -eu
ROOT=$PWD
LIB=$1
MODE=$2
export FM_REMOTE_JOB_STATE_ROOT="$ROOT/.validation/stage-$MODE-${LIB##*/}"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
. "$LIB"
ACCOUNT="$FM_REMOTE_JOB_STATE_ROOT/account"
mkdir -p "$ACCOUNT" "$FM_REMOTE_JOB_STATE_ROOT/home"
fm_remote_job_prepare_state "$ACCOUNT"
if [ "$MODE" = fault ]; then
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/1"
  mkdir() { command mkdir "$@" 2>/dev/null && return 0; [ "$#" -eq 1 ] && [ -d "$1" ]; }
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/1"
  pids=()
  for i in $(seq 1 20); do
    fm_remote_job_stage "$ACCOUNT" "$ROOT" "$FM_REMOTE_JOB_STATE_ROOT/home" fm-remote-doctor.sh < /dev/null > "$FM_REMOTE_JOB_STATE_ROOT/id-$i" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  python3 - "$FM_REMOTE_JOB_JOBS" <<'PY'
import pathlib,sys
jobs=sorted(pathlib.Path(sys.argv[1]).glob('job-*'))
values=[]
for job in jobs:
    value=int((job/'seq').read_text()); values.append(value)
    print(f'{job.name}: state={(job/"state").read_text().strip()} sequence={value}')
print('sorted published sequences:', sorted(values))
print('expected: every integer from 2 through 21 exactly once; legacy claim 1 must remain reserved')
assert sorted(values)==list(range(2,22)), 'published jobs reused a reserved sequence'
PY
elif [ "$MODE" = recovery ]; then
  python3 - "$FM_REMOTE_JOB_SEQ_CLAIMS" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])
for n in range(1,100001):
    if n==50000: (p/str(n)).mkdir()
    else: (p/str(n)).touch()
(p/'100009').mkdir(); (p/'100010').touch()
print('Seeded 100000 contiguous claims, mixed file/directory types, and high claims 100009/100010')
PY
  printf 'corrupt-hint\n' > "$FM_REMOTE_JOB_STATE/seq"
  fm_remote_job_stage "$ACCOUNT" "$ROOT" "$FM_REMOTE_JOB_STATE_ROOT/home" fm-remote-doctor.sh < /dev/null
  job="$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID"
  actual=$(fm_remote_job_read_number "$job" seq)
  printf 'Published job %s state=%s sequence=%s; expected sequence=100011 after bounded-walk rescan\n' "$FM_REMOTE_JOB_ID" "$(fm_remote_job_read_state "$job")" "$actual"
  [ "$actual" = 100011 ]
  printf '0\n' > "$FM_REMOTE_JOB_STATE/seq"
  rm "$FM_REMOTE_JOB_SEQ_CLAIMS/1"
  ln -s "$FM_REMOTE_JOB_STATE/seq" "$FM_REMOTE_JOB_SEQ_CLAIMS/1"
  if fm_remote_job_stage "$ACCOUNT" "$ROOT" "$FM_REMOTE_JOB_STATE_ROOT/home" fm-remote-doctor.sh < /dev/null; then
    echo 'ERROR: symlink claim accepted'; exit 1
  fi
  [ "$(cat "$FM_REMOTE_JOB_STATE/seq")" = 0 ]
  printf 'Symlink claim refused without altering its target: %s\n' "$FM_REMOTE_JOB_ERROR"
fi
