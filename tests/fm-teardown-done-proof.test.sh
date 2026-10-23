#!/usr/bin/env bash
# Consumer regression: fm-teardown.sh refuses a `done:` task that opted in with
# meta proof=required unless a complete proof packet exists; other tasks are unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-done-proof)
REAL_TMUX=$(command -v tmux) || fail "tmux is required for sandbox cleanup tests"
REAL_PS=$(command -v ps) || fail "ps is required for sandbox cleanup tests"

sandbox_tmux() {
  (cd "$1" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S dedicated.sock "${@:2}")
}

cleanup() {
  local dir
  for dir in "$TMP_ROOT"/*; do
    [ -d "$dir" ] || continue
    sandbox_tmux "$dir" kill-server 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

make_case() {  # <dir> <meta-extra>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/home/data/t1" "$dir/home/config" "$dir/fakebin" "$dir/project"
  git init -q "$dir/project"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  sandbox_tmux "$dir" -f /dev/null new-session -d -s proof -n control 'sleep 120' || exit 1
  sandbox_tmux "$dir" new-window -d -t proof: -n fm-t1 'sleep 120' || exit 1
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
cd '$dir' || exit 1
exec env -u TMUX -u TMUX_PANE '$REAL_TMUX' -S dedicated.sock "\$@"
SH
  cat > "$dir/fakebin/ps" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != -u ] || exit 0
exec '$REAL_PS' "\$@"
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/ps"
  printf 'kind=ship\nmode=local-only\nwindow=proof:fm-t1\nendpoint_task_id=t1\nproject=%s\nworktree=%s\n%s\n' \
    "$dir/project" "$dir/worktree" "${2:-}" > "$dir/home/state/t1.meta"
  printf 'done: PR https://example.invalid/pr/1\n' > "$dir/home/state/t1.status"
  printf '%s\n' "$dir"
}

run_teardown() {  # <dir>
  FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$1/fakebin:$PATH" \
    "$TEARDOWN" t1 --force > "$1/out" 2> "$1/err"
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
assert_present "$d/home/state/t1.meta" "meta removed despite refusal"
sandbox_tmux "$d" list-windows -t proof -F '#{window_name}' | grep -Fxq fm-t1 \
  || fail "endpoint removed despite missing packet refusal"

# 2. opt-in task, packet with a placeholder field: still refused
d=$(make_case optin-badpacket 'proof=required')
write_packet "$d"
sed -i.bak 's/^rollback:.*/rollback: TODO/' "$d/home/data/t1/done-proof.md"
run_teardown "$d" && fail "placeholder packet was accepted"
grep -q "requires a done proof packet" "$d/err" || fail "bad packet refusal is not the proof refusal"
assert_present "$d/home/state/t1.meta" "meta removed despite bad packet refusal"
sandbox_tmux "$d" list-windows -t proof -F '#{window_name}' | grep -Fxq fm-t1 \
  || fail "endpoint removed despite bad packet refusal"

d=$(make_case optin-goodpacket 'proof=required')
write_packet "$d"
run_teardown "$d" || fail "complete packet cleanup failed: $(< "$d/err")"
assert_absent "$d/home/state/t1.meta" "complete packet left task metadata"
windows=$(sandbox_tmux "$d" list-windows -t proof -F '#{window_name}') \
  || fail "complete packet cleanup removed the sandbox control session"
[ "$windows" = control ] || fail "complete packet cleanup did not remove only the task endpoint"

# 4. task without the opt-in: the proof gate is not consulted
d=$(make_case no-optin '')
run_teardown "$d" || fail "non opt-in cleanup failed: $(< "$d/err")"
assert_absent "$d/home/state/t1.meta" "non opt-in cleanup left task metadata"
windows=$(sandbox_tmux "$d" list-windows -t proof -F '#{window_name}') \
  || fail "non opt-in cleanup removed the sandbox control session"
[ "$windows" = control ] || fail "non opt-in cleanup did not remove only the task endpoint"

pass "teardown completion proof consumer"
