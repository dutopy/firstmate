#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "$ROOT/.remote-job-active-wait.XXXXXX")
WORKER_PID=
BURST_PID=
cleanup() {
  if [ -n "$BURST_PID" ]; then
    kill -TERM "$BURST_PID" 2>/dev/null || true
    wait "$BURST_PID" 2>/dev/null || true
  fi
  if [ -n "$WORKER_PID" ]; then
    kill -TERM "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=30 FM_REMOTE_JOB_TIMEOUT=30

for mode in fifo fallback; do
  fixture="$TMP_ROOT/$mode"
  code="$fixture/code"
  account="$fixture/account"
  export FM_REMOTE_JOB_STATE_ROOT="$fixture/state"
  mkdir -p "$code/bin" "$account"
  chmod 700 "$account"
  cp "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$code/bin/"
  printf 'fixture\n' > "$code/AGENTS.md"
  cat > "$code/bin/fm-gated-job.sh" <<'SH'
#!/bin/bash
printf 'started\n' > "$1"
while [ ! -f "$2" ]; do sleep 0.05; done
SH
  cat > "$code/bin/fm-next-job.sh" <<'SH'
#!/bin/bash
printf 'started\n' > "$1"
SH
  chmod +x "$code/bin/"*.sh
  git -C "$code" init -q -b main
  git -C "$code" -c user.name=Test -c user.email=test@example.com add .
  git -C "$code" -c user.name=Test -c user.email=test@example.com commit -qm fixture
  fm_remote_job_prepare_state "$account"
  if [ "$mode" = fifo ]; then
    exec 7<>"$FM_REMOTE_JOB_STATE_ROOT/worker.wake"
    printf '1\n' > "$FM_REMOTE_JOB_STATE_ROOT/worker.waiting"
  fi
  fm_remote_job_stage "$account" "$code" "$account" fm-gated-job.sh \
    "$fixture/first" "$fixture/release" </dev/null >/dev/null
  if [ "$mode" = fifo ]; then
    notification=
    IFS= read -r -n 1 -t 1 -u 7 notification || fail "publishing did not ring the FIFO"
    [ "$notification" = x ] || fail "publishing emitted an invalid FIFO notification"
    printf '0\n' > "$FM_REMOTE_JOB_STATE_ROOT/worker.waiting"
    (
      for ((ring=0; ring<70000; ring++)); do fm_remote_job_wake_worker; done
      : > "$fixture/burst-finished"
    ) &
    BURST_PID=$!
    for ((i=0; i<400; i++)); do
      [ ! -f "$fixture/burst-finished" ] || break
      sleep 0.05
    done
    assert_present "$fixture/burst-finished" "notifications blocked when no worker was waiting"
    wait "$BURST_PID"
    BURST_PID=
    if IFS= read -r -n 1 -t 1 -u 7 notification; then
      fail "publishing accumulated notifications when no worker was waiting"
    fi
    exec 7>&-
    pass "publishing rings a waiting worker without accumulating inactive notifications"
  fi
  if [ "$mode" = fallback ]; then
    rm "$FM_REMOTE_JOB_STATE_ROOT/worker.wake"
    : > "$FM_REMOTE_JOB_STATE_ROOT/worker.wake"
  fi
  HOME="$account" FM_ROOT_OVERRIDE="$code" \
    "$code/bin/fm-remote-job-worker.sh" --serve >"$fixture/out" 2>"$fixture/err" &
  WORKER_PID=$!
  for ((i=0; i<200; i++)); do
    [ ! -f "$fixture/first" ] || break
    sleep 0.05
  done
  assert_present "$fixture/first" "the $mode worker did not start its first job"
  if [ "$mode" = fifo ]; then
    IFS= read -r waiting < "$FM_REMOTE_JOB_STATE_ROOT/worker.waiting"
    [ "$waiting" = 0 ] || fail "an active lane advertised an idle FIFO wait"
  fi
  (
    fm_remote_job_stage "$account" "$code" "$account" fm-next-job.sh \
      "$fixture/second" </dev/null >/dev/null
    printf 'publisher stderr preserved\n' >&2
  ) 2>"$fixture/publisher.err"
  grep -q 'publisher stderr preserved' "$fixture/publisher.err" \
    || fail "the $mode publisher replaced its caller's stderr"
  sleep 0.3
  assert_absent "$fixture/second" "the $mode worker overlapped same-home jobs"
  : > "$fixture/release"
  for ((i=0; i<100; i++)); do
    [ ! -f "$fixture/second" ] || break
    sleep 0.05
  done
  assert_present "$fixture/second" "the $mode worker used its idle wait while a lane was active"
  [ ! -s "$fixture/err" ] || fail "the $mode worker emitted diagnostics during ordinary execution"
  pass "$mode scheduling remains prompt after a same-home publish while busy"

  if [ "$mode" = fifo ]; then
    waiting=
    for ((i=0; i<100; i++)); do
      IFS= read -r waiting < "$FM_REMOTE_JOB_STATE_ROOT/worker.waiting" || true
      [ "$waiting" != 1 ] || break
      sleep 0.05
    done
    [ "$waiting" = 1 ] || fail "the idle worker did not advertise its FIFO wait"
    rm -f "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
    mkdir "$FM_REMOTE_JOB_STATE_ROOT/worker.ready"
    fm_remote_job_wake_worker
    for ((i=0; i<100; i++)); do
      if grep -q 'cannot update worker heartbeat' "$fixture/err"; then break; fi
      sleep 0.05
    done
    grep -q 'cannot update worker heartbeat' "$fixture/err" \
      || fail "the worker lost its heartbeat failure diagnostic after opening the FIFO"
    pass "worker FIFO opening preserves operational stderr"
  fi
  kill -TERM "$WORKER_PID" 2>/dev/null || true
  wait "$WORKER_PID" 2>/dev/null || true
  WORKER_PID=
  if [ "$mode" = fifo ]; then
    IFS= read -r waiting < "$FM_REMOTE_JOB_STATE_ROOT/worker.waiting"
    [ "$waiting" = 0 ] || fail "the stopped worker still advertised a FIFO wait"
  fi
done
