#!/usr/bin/env bash
set -eu
LIB=$1
LABEL=$2
ROUNDS=${3:-25}
. "$LIB"
export FM_REMOTE_JOB_STATE_ROOT="$PWD/.validation/stress-$LABEL"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
mkdir -p "$FM_REMOTE_JOB_STATE_ROOT/account"
fm_remote_job_prepare_state "$FM_REMOTE_JOB_STATE_ROOT/account"
failures=0
for round in $(seq 1 "$ROUNDS"); do
  rm -rf "$FM_REMOTE_JOB_SEQ_CLAIMS"
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS"
  printf '0\n' > "$FM_REMOTE_JOB_STATE/seq"
  pids=()
  for i in $(seq 1 32); do
    fm_remote_job_next_seq > "$FM_REMOTE_JOB_STATE/out-$i" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  values=$(cat "$FM_REMOTE_JOB_STATE"/out-* | sort -n)
  if [ "$values" != "$(seq 1 32)" ]; then
    failures=$((failures+1))
    printf '%s round=%s incorrect allocations: %s\n' "$LABEL" "$round" "$(printf '%s' "$values" | tr '\n' ',')"
  else
    printf '%s round=%s allocated unique contiguous sequences 1..32\n' "$LABEL" "$round"
  fi
done
printf '%s failed_rounds=%s/%s\n' "$LABEL" "$failures" "$ROUNDS"
[ "$failures" = 0 ]
