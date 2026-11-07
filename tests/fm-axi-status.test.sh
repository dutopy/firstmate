#!/usr/bin/env bash
# Behavioral coverage for the public AXI status reader/writer executable.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-axi-status)
HOME_DIR="$TMP_ROOT/home"
AXI="$ROOT/bin/fm-axi-status.sh"
mkdir -p "$HOME_DIR/state"
export FM_HOME="$HOME_DIR"
expect_fail() { if "$@" >"$TMP_ROOT/unexpected.out" 2>"$TMP_ROOT/unexpected.err"; then fail "expected failure: $*"; fi; }

# The public help and structured diagnostics are part of the machine contract.
"$AXI" --help > "$TMP_ROOT/help" || fail "help failed"
grep -F -- '--task-id ID --state STATE' "$TMP_ROOT/help" >/dev/null || fail "help omitted required writer fields"
"$AXI" write --help > "$TMP_ROOT/write-help" || fail "writer help failed"
"$AXI" validate --help > "$TMP_ROOT/validate-help" || fail "validator help failed"
grep -F -- '--merge-state open|merged|unknown' "$TMP_ROOT/write-help" >/dev/null || fail "writer help omitted merge states"
grep -F -- 'validate [FILE]' "$TMP_ROOT/validate-help" >/dev/null || fail "validator help omitted file form"
expect_fail "$AXI" write --task-id bad --state INVALID
ERROR=$(cat "$TMP_ROOT/unexpected.err")
printf '%s\n' "$ERROR" | grep -F 'error:' >/dev/null || fail "error was not structured"
printf '%s\n' "$ERROR" | grep -F 'code: INVALID_STATE' >/dev/null || fail "error code missing"
printf '%s\n' "$ERROR" | grep -F 'field: state' >/dev/null || fail "error field missing"

# First write provisions an empty home. Required fields and delivery references fail closed.
FRESH="$TMP_ROOT/fresh"
mkdir -p "$FRESH"
EMPTY=$(FM_HOME="$FRESH" "$AXI") || fail "empty-home aggregate failed"
[ "$EMPTY" = 'no AXI records' ] || fail "empty home lacked explicit empty state"
FM_HOME="$FRESH" "$AXI" write --task-id fresh --state working >/dev/null || fail "fresh-home write failed"
expect_fail "$AXI" write --state 'done'
expect_fail "$AXI" write --task-id delivery --state 'done' --kind delivery
expect_fail "$AXI" write --task-id x --state 'done' --unknown value
"$AXI" write --task-id path-only --state 'done' --kind delivery --path /private/path-only >/dev/null \
  || fail "path-only delivery failed"
"$AXI" write --task-id pr-only --state 'done' --kind delivery --pr https://github.com/example/project/pull/7 >/dev/null \
  || fail "PR-only delivery failed"
"$AXI" write --task-id merge-input --state 'done' --kind delivery \
  --pr https://github.com/example/project/pull/8 --merge-state merged >/dev/null \
  || fail "explicit identity-bound merge input failed"

# Legacy event history stays byte-identical and never masquerades as current state.
printf 'blocked: historical event\n' > "$HOME_DIR/state/ship.status"
LEGACY_HASH=$(sha256sum "$HOME_DIR/state/ship.status")
mkdir -p "$TMP_ROOT/worktree"
git -C "$TMP_ROOT/worktree" init -q
git -C "$TMP_ROOT/worktree" config user.email fmtest@example.invalid
git -C "$TMP_ROOT/worktree" config user.name fmtest
git -C "$TMP_ROOT/worktree" commit -q --allow-empty -m init
git -C "$TMP_ROOT/worktree" checkout -q -b fm/ship
HEAD_ID=$(git -C "$TMP_ROOT/worktree" rev-parse HEAD)
SHORT_HEAD=${HEAD_ID%"${HEAD_ID#???????}"}
printf 'task_id=ship\nworktree=%s\nkind=ship\npr=https://github.com/example/project/pull/42\n' "$TMP_ROOT/worktree" > "$HOME_DIR/state/ship.meta"
# shellcheck disable=SC2016 # Literal script body for the fake tmux executable.
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "%%1\\n";; capture-pane) printf "quiet\\n> \\n";; esac\n' > "$TMP_ROOT/tmux"
chmod +x "$TMP_ROOT/tmux"
cat > "$TMP_ROOT/no-mistakes" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = axi ] && [ "\${2:-}" = status ]; then
cat <<OUT
run:
  id: "01AXI"
  branch: fm/ship
  status: running
  head: "$HEAD_ID"
  pr: ""
  findings: none
  steps[1]{step,status,findings,duration_ms}:
    review,running,0,0
OUT
elif [ "\${1:-}" = runs ]; then
  printf '  running    fm/ship $SHORT_HEAD  2026-09-08 09:00\n'
fi
EOF
chmod +x "$TMP_ROOT/no-mistakes"
export PATH="$TMP_ROOT:$PATH"

PATH_VALUE=/private/axi-phase1-fixture/artifact-with-a-canonical-long-name
PR_VALUE=https://github.com/example/project/pull/42
"$AXI" write --task-id ship --state 'done' --kind delivery --path "$PATH_VALUE" --pr "$PR_VALUE" --merge-state open --event-id e1 >/dev/null || fail "delivery write failed"
"$AXI" write --task-id other --state blocked --capability unavailable --error-code NEEDS_INPUT --error-message 'captain must choose' --event-id other-1 >/dev/null || fail "error write failed"

# Exact retries and repeated unkeyed operations converge; collisions validate before dedupe.
BEFORE=$(sha256sum "$HOME_DIR/state/axi-status.v1.log")
"$AXI" write --task-id ship --state 'done' --kind delivery --path "$PATH_VALUE" --pr "$PR_VALUE" --merge-state open --event-id e1 > "$TMP_ROOT/retry" || fail "exact retry failed"
grep -qx unchanged "$TMP_ROOT/retry" || fail "exact retry did not converge"
expect_fail "$AXI" write --task-id ship --state INVALID --event-id e1
expect_fail "$AXI" write --task-id collision --state 'done' --event-id e1
expect_fail "$AXI" write --task-id collision --state 'done' --kind delivery --event-id e1
[ "$BEFORE" = "$(sha256sum "$HOME_DIR/state/axi-status.v1.log")" ] || fail "invalid retry changed history"
"$AXI" write --task-id repeat --state 'done' >/dev/null || fail "first unkeyed write failed"
"$AXI" write --task-id repeat --state 'done' > "$TMP_ROOT/repeat" || fail "repeated unkeyed write failed"
grep -qx unchanged "$TMP_ROOT/repeat" || fail "repeated unkeyed write did not converge"

# Updates append a complete immutable event while preserving every prior event.
cp "$HOME_DIR/state/axi-status.v1.log" "$TMP_ROOT/prior-journal"
PRIOR_BYTES=$(LC_ALL=C wc -c < "$TMP_ROOT/prior-journal")
"$AXI" write --update --task-id ship --state working --event-id e2 >/dev/null || fail "update failed"
[ "$(grep -c 'task_id=ship' "$HOME_DIR/state/axi-status.v1.log")" -eq 2 ] || fail "immutable event history was not retained"
dd if="$HOME_DIR/state/axi-status.v1.log" bs=1 count="$PRIOR_BYTES" 2>/dev/null \
  | cmp -s "$TMP_ROOT/prior-journal" - || fail "update changed prior event bytes"
[ "$LEGACY_HASH" = "$(sha256sum "$HOME_DIR/state/ship.status")" ] || fail "legacy history was rewritten"
UPDATED_HASH=$(sha256sum "$HOME_DIR/state/axi-status.v1.log")
"$AXI" write --update --task-id ship --state working --event-id e2 > "$TMP_ROOT/update-retry" \
  || fail "update retry failed"
grep -qx unchanged "$TMP_ROOT/update-retry" || fail "update retry did not converge"
[ "$UPDATED_HASH" = "$(sha256sum "$HOME_DIR/state/axi-status.v1.log")" ] || fail "update retry changed history"

# Writers serialize and readers see only complete old or new journals.
pids=""
for i in $(seq 1 10); do
  "$AXI" --full > "$TMP_ROOT/concurrent-read.$i" & pids="$pids $!"
  "$AXI" write --task-id "concurrent-$i" --state working --event-id "concurrent-$i" \
    > "$TMP_ROOT/concurrent-write.$i" & pids="$pids $!"
done
for pid in $pids; do wait "$pid" || fail "concurrent reader or writer failed"; done
"$AXI" validate "$HOME_DIR/state/axi-status.v1.log" >/dev/null || fail "concurrent publication produced an invalid journal"

# Invalid percent triplets and invalid encoded UTF-8 fail from regular files.
printf 'axi-status.v1 task_id=bad state=done path=%%ZZ\n' > "$TMP_ROOT/bad-percent"
printf 'axi-status.v1 task_id=bad state=done path=%%FF\n' > "$TMP_ROOT/bad-utf8"
expect_fail "$AXI" validate "$TMP_ROOT/bad-percent"
expect_fail "$AXI" validate "$TMP_ROOT/bad-utf8"
"$AXI" validate "$HOME_DIR/state/axi-status.v1.log" >/dev/null || fail "valid journal rejected"

# The no-argument aggregate uses the real current reader and preserves canonical details.
DEFAULT=$(cd /tmp && FM_HOME="$HOME_DIR" "$AXI") || fail "no-argument aggregate failed"
printf '%s\n' "$DEFAULT" | grep -F 'ship | working | delivery' >/dev/null \
  || fail "no-argument aggregate omitted live task"
FULL=$(cd /tmp && FM_HOME="$HOME_DIR" "$AXI" --full) || fail "full aggregate failed"
printf '%s\n' "$FULL" | grep -F 'ship | working | delivery' >/dev/null || fail "stale event overrode live current state"
printf '%s\n' "$FULL" | grep -F "path=$PATH_VALUE" >/dev/null || fail "full output lost path"
printf '%s\n' "$FULL" | grep -F "pr=$PR_VALUE" >/dev/null || fail "full output lost PR"
printf '%s\n' "$FULL" | grep -F 'merge_state=open' >/dev/null || fail "identity-bound open evidence missing"
printf '%s\n' "$FULL" | grep -F 'other | unknown | event' >/dev/null || fail "orphan event masqueraded as current state"
printf '%s\n' "$FULL" | grep -F 'other | unknown | event | capability=unavailable | error=NEEDS_INPUT' >/dev/null \
  || fail "full output lost named capability or error"
printf '%s\n' "$FULL" | grep -F 'error_message=captain must choose' >/dev/null \
  || fail "full output lost error message"
printf '%s\n' "$FULL" | grep -F 'merge-input | unknown | delivery' | grep -F 'merge_state=merged' >/dev/null \
  || fail "explicit identity-bound merged evidence missing"
printf '%s\n' "$FULL" | grep -F 'pr-only | unknown | delivery' | grep -F 'merge_state=unknown' >/dev/null \
  || fail "missing merge evidence did not render unknown"

# Exact merge marker overrides current identity; mismatched evidence is unknown.
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nexample/project\n42\n' > "$HOME_DIR/state/ship.pr-poll-merge-notified"
"$AXI" --full | grep -F 'ship | working | delivery' | grep -F 'merge_state=merged' >/dev/null || fail "merged evidence missing"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nother/project\n42\n' > "$HOME_DIR/state/ship.pr-poll-merge-notified"
"$AXI" --full | grep -F 'ship | working | delivery' | grep -F 'merge_state=open' >/dev/null || fail "mismatch did not fall back to current writer evidence"
printf 'task_id=ship\nworktree=%s\nkind=ship\npr=\n' "$TMP_ROOT/worktree" > "$HOME_DIR/state/ship.meta"
CLEARED=$("$AXI" --full | grep -F 'ship | working | delivery') || fail "cleared-identity aggregate failed"
printf '%s\n' "$CLEARED" | grep -F 'merge_state=unknown' >/dev/null || fail "cleared PR retained merge evidence"
if printf '%s\n' "$CLEARED" | grep -F 'pr=' >/dev/null; then fail "cleared PR retained canonical identity"; fi
printf 'task_id=ship\nworktree=%s\nkind=ship\npr=https://github.com/example/new/pull/7\n' "$TMP_ROOT/worktree" > "$HOME_DIR/state/ship.meta"
"$AXI" --full | grep -F 'ship | working | delivery' | grep -F 'merge_state=unknown' >/dev/null || fail "stale PR evidence was trusted"

# Compact output is controlled-width, preserves critical signals, and discloses full details.
COMPACT=$("$AXI" --width 20) || fail "compact aggregate failed"
while IFS= read -r line; do [ "${#line}" -le 20 ] || fail "line exceeds width: $line"; done <<< "$COMPACT"
printf '%s\n' "$COMPACT" | grep -F 'capability=' >/dev/null || fail "capability label missing"
printf '%s\n' "$COMPACT" | grep -F 'NEEDS_INPUT' >/dev/null || fail "error code missing"
printf '%s\n' "$COMPACT" | grep -F 'rerun --full' >/dev/null || fail "full-details route missing"
CONTROLLED=$("$AXI" --width 80) || fail "controlled-width aggregate failed"
while IFS= read -r line; do [ "${#line}" -le 80 ] || fail "line exceeds controlled width: $line"; done <<< "$CONTROLLED"

# Fixed same-input proxy: complete representations carry identical values and scope.
printf 'task_id=ship\nworktree=%s\nkind=ship\npr=%s\n' "$TMP_ROOT/worktree" "$PR_VALUE" > "$HOME_DIR/state/ship.meta"
"$AXI" write --update --task-id ship --state working --merge-state unknown --event-id e3 >/dev/null \
  || fail "proxy fixture update failed"
AFTER_ROW=$("$AXI" --full | grep '^ship ')
EXPECTED_ROW="ship | working | delivery | path=$PATH_VALUE | pr=$PR_VALUE | merge_state=unknown"
[ "$AFTER_ROW" = "$EXPECTED_ROW" ] || fail "proxy representations differ: $AFTER_ROW"
BEFORE_BYTES=$(printf '%s\n' "$EXPECTED_ROW" | LC_ALL=C wc -c)
AFTER_BYTES=$(printf '%s\n' "$AFTER_ROW" | LC_ALL=C wc -c)
BEFORE_PROXY=$(( (BEFORE_BYTES + 3) / 4 ))
AFTER_PROXY=$(( (AFTER_BYTES + 3) / 4 ))
printf 'token-proxy-estimate fixture=phase1-ship-v1 method=complete-single-task-full-row-LC_ALL_C-wc-c-ceiling-bytes-div-4 before_bytes=%s after_bytes=%s before_bytes_div_4=%s after_bytes_div_4=%s\n' "$BEFORE_BYTES" "$AFTER_BYTES" "$BEFORE_PROXY" "$AFTER_PROXY"

pass "axi status preserves event history, reconciles current state, and validates structured delivery records"
