#!/usr/bin/env bash
# Behavior tests for fm-inbox.sh external-source idempotency.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-inbox-external-tests)
HOME1="$TMP_ROOT/home"
mkdir -p "$HOME1/state" "$HOME1/data"

note_count() {
  find "$HOME1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

wake_count() {
  awk 'END { print NR + 0 }' "$HOME1/state/.wake-queue" 2>/dev/null
}

META="$TMP_ROOT/meta.json"
printf '{"profile":"proapplis","message_id":"999999999999999999"}\n' > "$META"

out=$(FM_HOME="$HOME1" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id discord:111111111111111111:222222222222222222:999999999999999999 \
  --metadata-file "$META" - <<'EOF'
Discord note body.
EOF
)
assert_contains "$out" "queued" "external note queues a note"
first_id=$(printf '%s\n' "$out" | awk '/^queued / { print $2; exit }')
[ -n "$first_id" ] || fail "could not parse the queued note id"
[ "$(note_count)" = 1 ] || fail "external note created the wrong note count"
[ "$(wake_count)" = 1 ] || fail "external note created the wrong wake count"
assert_grep "external_source=discord-workspace" "$HOME1/state/inbox/$first_id.note" "external source is recorded in the note"
assert_grep "external_id=discord:111111111111111111:222222222222222222:999999999999999999" "$HOME1/state/inbox/$first_id.note" "external id is recorded in the note"
assert_present "$HOME1/state/inbox/external" "external source map directory exists"
metadata_copy=$(sed -n 's/^external_metadata=//p' "$HOME1/state/inbox/$first_id.note")
assert_present "$metadata_copy" "metadata file is copied into private inbox state"
assert_grep '"profile"' "$metadata_copy" "metadata copy keeps the bounded JSON"
pass "external-source note records one note, one wake, and private metadata"

out2=$(FM_HOME="$HOME1" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id discord:111111111111111111:222222222222222222:999999999999999999 \
  --metadata-file "$META" - <<'EOF'
Replay body that must not create a new note.
EOF
)
assert_contains "$out2" "queued $first_id" "replay returns the first note id"
assert_contains "$out2" "no new wake" "replay reports that no wake was appended"
[ "$(note_count)" = 1 ] || fail "replay created a duplicate note"
[ "$(wake_count)" = 1 ] || fail "replay created a duplicate wake"
pass "external-source replay is idempotent"

bad_status=0
bad_out=$(FM_HOME="$HOME1" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id 'discord:bad/slash' - <<< 'bad' 2>&1) || bad_status=$?
[ "$bad_status" -ne 0 ] || fail "invalid external id was accepted"
assert_contains "$bad_out" "external id" "invalid external id refusal names the problem"
pass "external source ids are validated before queuing"
