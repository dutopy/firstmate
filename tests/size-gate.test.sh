#!/usr/bin/env bash
# Real Git histories prove size boundaries, exclusions, renames and read failures.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot size-gate)
failures=0
new_repo() {
  repo="$TMP_ROOT/$1"
  mkdir -p "$repo"
  cd "$repo"
  git init -q
  git config user.name Test
  git config user.email test@example.invalid
  git commit -qm base --allow-empty
  base=$(git rev-parse HEAD)
}
lines() {
  local i
  mkdir -p "$(dirname "./$1")"
  for ((i=0; i<$2; i++)); do printf 'line %s\n' "$i"; done > "$1"
}
commit() { git add -A; git commit -qm change; }
check() {
  local label=$1 expected_rc=$2 expected=$3 rc=0 actual
  shift 3
  actual=$(bash "$ROOT/bin/size-gate.sh" "$@" 2>"$TMP_ROOT/error") || rc=$?
  if [ "$rc" != "$expected_rc" ] || [ "$actual" != "$expected" ]; then
    printf 'not ok - %s: rc=%s output=%s\n' "$label" "$rc" "$actual" >&2
    failures=$((failures + 1))
  else
    pass "$label"
  fi
}
new_repo line-boundary
lines code 400; commit
check '400 lines accepted' 0 'added=400 deleted=0 lines=400 files=1 max_lines=400 max_files=15' "$base"
lines code 401; commit
check '401 lines rejected despite environment overrides' 1 'added=401 deleted=0 lines=401 files=1 max_lines=400 max_files=15' "$base"
export MAX_ADDED=99999 MAX_FILES=99999 EXCLUDE='.*'
check 'environment cannot loosen limits' 1 'added=401 deleted=0 lines=401 files=1 max_lines=400 max_files=15' "$base"
unset MAX_ADDED MAX_FILES EXCLUDE
new_repo deletion
lines code 401; commit
base=$(git rev-parse HEAD)
rm code; commit
check 'deletions count toward threshold' 1 'added=0 deleted=401 lines=401 files=1 max_lines=400 max_files=15' "$base"
new_repo mixed
lines code 200; commit
base=$(git rev-parse HEAD)
for ((i=1; i<=200; i++)); do printf 'replacement %s\n' "$i"; done > code
commit
check 'mixed 400 lines accepted' 0 'added=200 deleted=200 lines=400 files=1 max_lines=400 max_files=15' "$base"
printf 'extra\n' >> code; commit
check 'mixed 401 lines rejected' 1 'added=201 deleted=200 lines=401 files=1 max_lines=400 max_files=15' "$base"
new_repo file-boundary
for ((i=1; i<=15; i++)); do lines "code$i" 1; done
commit
check '15 files accepted' 0 'added=15 deleted=0 lines=15 files=15 max_lines=400 max_files=15' "$base"
lines code16 1; commit
check '16 files rejected' 1 'added=16 deleted=0 lines=16 files=16 max_lines=400 max_files=15' "$base"
new_repo exclusions
for path in package-lock.json nested/package-lock.json pnpm-lock.yaml uv.lock nested/a.snap docs/external/manual tests/fixtures/input; do lines "$path" 401; done
printf '\0binary' > tests/fixtures/binary
commit
check 'approved exclusions include excluded binary' 0 'added=0 deleted=0 lines=0 files=0 max_lines=400 max_files=15' "$base"
new_repo near-misses
for path in package-lock.json.code mypnpm-lock.yaml uv.locked a.snap.code docs/externality/manual other/docs/external/manual tests/fixtures-extra/input other/tests/fixtures/input; do lines "$path" 1; done
commit
check 'exclusions are path-aware and narrow' 0 'added=8 deleted=0 lines=8 files=8 max_lines=400 max_files=15' "$base"
new_repo odd-paths
for path in 'space name' $'tab\tname' $'line\nname' '-leading' 'unicode-é'; do lines "$path" 1; done
commit
check 'odd paths measured intact' 0 'added=5 deleted=0 lines=5 files=5 max_lines=400 max_files=15' "$base"
new_repo rename
lines old 20; commit
base=$(git rev-parse HEAD)
git mv old $'new\tname'; commit
check 'rename counts once' 0 'added=0 deleted=0 lines=0 files=1 max_lines=400 max_files=15' "$base"
new_repo exclusion-crossing
lines tests/fixtures/input 401; commit
base=$(git rev-parse HEAD)
git mv tests/fixtures/input code; commit
check 'rename into included path is counted' 0 'added=0 deleted=0 lines=0 files=1 max_lines=400 max_files=15' "$base"
new_repo binary
printf '\0binary' > code; commit
check 'included binary cannot be measured' 2 '' "$base"
base=$(git rev-parse HEAD)
rm code; commit
check 'included binary deletion cannot be measured' 2 '' "$base"
new_repo refs
check 'invalid base refused' 2 '' nonexistent HEAD
check 'invalid head refused' 2 '' HEAD nonexistent
check 'empty ref refused' 2 '' '' HEAD
check 'option-like ref refused' 2 '' --stat HEAD
check 'extra argument refused' 2 '' HEAD HEAD HEAD
check 'missing origin/main refused' 2 ''
git update-ref refs/remotes/origin/main HEAD
lines code 1; commit
check 'default merge base and HEAD' 0 'added=1 deleted=0 lines=1 files=1 max_lines=400 max_files=15'
check 'explicit head and base' 0 'added=1 deleted=0 lines=1 files=1 max_lines=400 max_files=15' "$base" HEAD
check 'unchanged diff measured' 0 'added=0 deleted=0 lines=0 files=0 max_lines=400 max_files=15' HEAD HEAD
cd "$TMP_ROOT"
new_repo relative-config
lines outside 401
mkdir nested
commit
git config diff.relative true
cd nested
check 'subdirectory and relative config cannot hide changes' 1 'added=401 deleted=0 lines=401 files=1 max_lines=400 max_files=15' "$base"
cd "$TMP_ROOT"
check 'outside repository refused' 2 '' HEAD HEAD
[ "$failures" -eq 0 ] || fail "$failures size-gate assertions failed"
