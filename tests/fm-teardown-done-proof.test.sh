#!/usr/bin/env bash
# Consumer regression: fm-teardown.sh refuses a `done:` task that opted in with
# meta proof=required unless a complete proof packet exists; other tasks are unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-done-proof)

make_case() {  # <dir> <meta-extra>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/home/data/t1" "$dir/home/config" "$dir/worktree" "$dir/project"
  git init -q "$dir/project"
  printf 'kind=ship\nworktree=%s\n%s\n' "$dir/worktree" "${2:-}" > "$dir/home/state/t1.meta"
  printf 'done: PR https://example.invalid/pr/1\n' > "$dir/home/state/t1.status"
  printf '%s\n' "$dir"
}

run_teardown() {  # <dir>
  FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" "$TEARDOWN" t1 --force > "$1/out" 2> "$1/err"
}

write_packet() {  # <dir>
  cat > "$1/home/data/t1/done-proof.md" <<'EOF'
root_cause: stale cache key
regression_test: tests/fm-teardown-done-proof.test.sh
retest: passed after the change
authoritative_state: status file re-read after the change
artifact_or_scope: bin/fm-teardown.sh
rollback: git revert the commit
EOF
}

# 1. opt-in task, done claimed, no packet: refused before any change
d=$(make_case optin-nopacket 'proof=required')
run_teardown "$d" && fail "opt-in done without packet was accepted"
grep -q "requires a done proof packet" "$d/err" || fail "refusal does not name the proof packet"
[ -f "$d/home/state/t1.meta" ] || fail "meta removed despite refusal"

# 2. opt-in task, packet with a placeholder field: still refused
d=$(make_case optin-badpacket 'proof=required')
write_packet "$d"
sed -i.bak 's/^rollback:.*/rollback: TODO/' "$d/home/data/t1/done-proof.md"
run_teardown "$d" && fail "placeholder packet was accepted"
grep -q "requires a done proof packet" "$d/err" || fail "bad packet refusal is not the proof refusal"

# 3. opt-in task, complete packet: the proof gate passes (a later, unrelated step may still stop)
d=$(make_case optin-goodpacket 'proof=required')
write_packet "$d"
run_teardown "$d"
grep -q "requires a done proof packet" "$d/err" && fail "complete packet was refused by the proof gate"

# 4. task without the opt-in: the proof gate is not consulted
d=$(make_case no-optin '')
run_teardown "$d"
grep -q "requires a done proof packet" "$d/err" && fail "non opt-in task hit the proof gate"

pass "teardown completion proof consumer"
