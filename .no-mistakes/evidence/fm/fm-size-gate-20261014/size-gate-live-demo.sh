#!/usr/bin/env bash
# Live demo of the shipped bin/size-gate.sh against a real Git repo.
# Run from the worktree root so ROOT points at the shipped artifact.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Locate the worktree's gate via an explicit argument (no redirect seam).
GATE=${1:?usage: size-gate-live-demo.sh /path/to/bin/size-gate.sh}
GATE_ROOT=$(cd "$(dirname "$GATE")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/size-gate-demo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

run_case() {
  local name=$1 expected_rc=$2
  shift 2
  local out rc=0
  out=$("$@" 2>"$WORK/stderr") || rc=$?
  local err; err=$(cat "$WORK/stderr")
  if [ "$rc" = "$expected_rc" ]; then
    printf 'ok   - %-52s rc=%s | %s\n' "$name" "$rc" "${out:-$err}"
  else
    printf 'FAIL - %-52s expected_rc=%s rc=%s | %s\n' "$name" "$expected_rc" "$rc" "${out:-$err}"
  fi
}

new_repo() {
  repo="$WORK/$1"; mkdir -p "$repo"; cd "$repo"
  git init -q; git config user.name Demo; git config user.email demo@example.invalid
  git commit -qm base --allow-empty; base=$(git rev-parse HEAD)
}
lines() { local i; mkdir -p "$(dirname "./$1")"; for ((i=0;i<$2;i++)); do printf 'line %s\n' "$i"; done > "$1"; }
commit() { git add -A; git commit -qm change; }

echo "== size-gate live demo =="
echo "gate: $GATE"
bash "$GATE" --help >/dev/null 2>&1 && echo "ok   - --help exits 0" || echo "FAIL - --help"
echo

echo "-- boundary: 400 added+deleted lines vs 401 --"
new_repo lines
lines code 400; commit
run_case "400 lines: accepted" 0 bash "$GATE" "$base"
lines code 401; commit
run_case "401 lines: alert (oversized)" 1 bash "$GATE" "$base"
run_case "401 lines with MAX_ADDED=99999 env: still alerts" 1 env MAX_ADDED=99999 MAX_FILES=99999 EXCLUDE='.*' bash "$GATE" "$base"
echo

echo "-- boundary: 15 files vs 16 files --"
new_repo files
for ((i=1;i<=15;i++)); do lines "code$i" 1; done; commit
run_case "15 files: accepted" 0 bash "$GATE" "$base"
lines code16 1; commit
run_case "16 files: alert (oversized)" 1 bash "$GATE" "$base"
echo

echo "-- exclusions: lockfiles / snapshots / external docs / fixtures --"
new_repo excl
for p in package-lock.json nested/package-lock.json pnpm-lock.yaml uv.lock nested/a.snap docs/external/manual tests/fixtures/input; do lines "$p" 401; done
commit
run_case "excluded trees ignored (would be 2807 lines otherwise)" 0 bash "$GATE" "$base"
new_repo nearmiss
for p in package-lock.json.code mypnpm-lock.yaml uv.locked a.snap.code docs/externality/manual other/docs/external/manual tests/fixtures-extra/input other/tests/fixtures/input; do lines "$p" 1; done
commit
run_case "near-miss paths are NOT excluded" 0 bash "$GATE" "$base"
echo

echo "-- deletions, renames, binaries, refs --"
new_repo deletion
lines code 401; commit; base=$(git rev-parse HEAD); rm code; commit
run_case "deletions count toward 400" 1 bash "$GATE" "$base"
new_repo rename
lines old 20; commit; base=$(git rev-parse HEAD); git mv old new; commit
run_case "rename counts once (0+0, files=1)" 0 bash "$GATE" "$base"
new_repo binary
printf '\0binary' > code; commit
run_case "included binary is a measurement failure" 2 bash "$GATE" "$base"
new_repo refs
run_case "option-like ref refused (no arg injection)" 2 bash "$GATE" --stat HEAD
run_case "extra argument refused" 2 bash "$GATE" HEAD HEAD HEAD
echo

echo "-- default mode in the real worktree --"
cd "$GATE_ROOT"
run_case "default merge-base(origin/main,HEAD)..HEAD on this change" 0 bash "$GATE"
