#!/bin/bash
# Disposable product CLI verification. ROOT and LAB must be supplied explicitly.
set -eu
: "${ROOT:?}" "${LAB:?}"
mkdir -p "$LAB/home/config" "$LAB/home/state" "$LAB/harness"
ln -s /bin/bash "$LAB/harness/omp"
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
export ROOT LAB
"$LAB/harness/omp" -c '
set -eu
marker="$FM_CONFIG_OVERRIDE/manual-promotion-required"
lock="$FM_STATE_OVERRIDE/.lock"
run() {
  expected=$1; shift
  printf "\n$"; printf " %q" "$@"; printf "\n"
  set +e
  "$@"
  actual=$?
  set -e
  printf "exit=%s (expected %s)\n" "$actual" "$expected"
  test "$actual" = "$expected"
}
state() {
  if test -L "$marker"; then m=symlink; elif test -e "$marker"; then m=present; else m=absent; fi
  if test -f "$lock"; then p=$(cat "$lock"); else p=absent; fi
  printf "observed marker=%s session_lock=%s actual_session_pid=%s\n" "$m" "$p" "$$"
}
printf "SCENARIO: Ordinary home acquires its actual session PID\n"
run 0 bash "$ROOT/bin/fm-lock.sh"
test "$(cat "$lock")" = "$$"
state
rm "$lock"
printf "\nSCENARIO: Standby blocks acquisition without publishing a lock, regardless of age\n"
: > "$marker"
run 1 bash "$ROOT/bin/fm-lock.sh"
test ! -e "$lock"
state
touch -t 200001010000 "$marker"
run 1 bash "$ROOT/bin/fm-lock.sh"
test ! -e "$lock"
state
printf "\nSCENARIO: Standby blocks the same-owner shortcut without changing its existing lock\n"
printf "%s\n" "$$" > "$lock"
run 1 bash "$ROOT/bin/fm-lock.sh"
test "$(cat "$lock")" = "$$"
state
printf "\nSCENARIO: Help, status, missing confirmation and extra arguments never promote\n"
run 0 bash "$ROOT/bin/fm-primary-promote.sh" --help
run 0 bash "$ROOT/bin/fm-lock.sh" status
run 2 bash "$ROOT/bin/fm-primary-promote.sh"
run 2 bash "$ROOT/bin/fm-primary-promote.sh" --confirm-other-primary-stopped extra
test -f "$marker"
test "$(cat "$lock")" = "$$"
state
printf "\nSCENARIO: Explicit promotion only clears the marker; repetition is inert\n"
run 0 bash "$ROOT/bin/fm-primary-promote.sh" --confirm-other-primary-stopped
test ! -e "$marker"
test "$(cat "$lock")" = "$$"
run 0 bash "$ROOT/bin/fm-primary-promote.sh" --confirm-other-primary-stopped
state
rm "$lock"
printf "\nSCENARIO: Promoted home acquires its own PID and rejects a competing live session\n"
run 0 bash "$ROOT/bin/fm-lock.sh"
test "$(cat "$lock")" = "$$"
run 1 "$LAB/harness/omp" -c '\''bash "$ROOT/bin/fm-lock.sh"; rc=$?; printf "competing_session_pid=%s exit=%s\n" "$$" "$rc"; exit "$rc"'\''
test "$(cat "$lock")" = "$$"
state
rm "$lock"
printf "\nSCENARIO: Dangling symlink and directory markers refuse both admission and promotion\n"
ln -s "$FM_HOME/missing-target" "$marker"
run 1 bash "$ROOT/bin/fm-lock.sh"
run 1 bash "$ROOT/bin/fm-primary-promote.sh" --confirm-other-primary-stopped
test -L "$marker"; test ! -e "$lock"
state
rm "$marker"
mkdir "$marker"
run 1 bash "$ROOT/bin/fm-lock.sh"
run 1 bash "$ROOT/bin/fm-primary-promote.sh" --confirm-other-primary-stopped
test -d "$marker"; test ! -e "$lock"
state
'
