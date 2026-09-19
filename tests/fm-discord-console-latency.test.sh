#!/usr/bin/env bash
# Focused tests for the Discord conversation console latency work:
#   1. a local wake append kicks a waiting watcher so a captain inbox note is
#      surfaced at once instead of after the poll interval, and with the kick
#      disabled the same note waits (the durable poll fallback still owns it);
#   2. the read-only `latency` report folds the durable watcher/inbox markers
#      into the five measured stages.
# Never touches a real home; every path is an isolated test directory.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WATCH="$ROOT/bin/fm-watch.sh"
INBOX="$ROOT/bin/fm-inbox.sh"
CONSOLE="$ROOT/bin/fm-discord-conversation-console.sh"
TMP_ROOT=$(fm_test_tmproot fm-discord-console-latency-tests)

start_watcher() {  # <dir> <out> <poll>
  local dir=$1 out=$2 poll=$3
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL="$poll" FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WAKE_QUEUE_POLL_DISABLE=1 \
    "$WATCH" > "$out" 2>&1 &
  echo $!
}

# ---------------------------------------------------------------------------
# 1. wake nudge A/B
# ---------------------------------------------------------------------------
dir=$(make_case nudge-fast)
state="$dir/state"
passdir="$TMP_ROOT/nudge-fast-pid"
mkdir -p "$passdir"
pid=$(start_watcher "$dir" "$dir/watch.out" 30)
# Let the first cycle finish and the terminal wait begin.
sleep 2
if ! kill -0 "$pid" 2>/dev/null; then
  fail "the watcher exited before the note was appended: $(cat "$dir/watch.out")"
fi
FM_STATE_OVERRIDE="$state" FM_HOME="$dir" "$INBOX" note --source discord --external-id 1000000000000000001 "Latency nudge measurement" >/dev/null 2>&1 \
  || fail "the inbox note could not be queued"
i=0
surfaced=0
while [ "$i" -lt 60 ]; do
  ls "$state"/.seen-inbox-* >/dev/null 2>&1 && { surfaced=1; break; }
  kill -0 "$pid" 2>/dev/null || { surfaced=0; break; }
  sleep 0.1
  i=$((i + 1))
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
[ "$surfaced" = 1 ] || fail "the nudge did not surface the note within 6s (elapsed $((i))0ms): $(cat "$dir/watch.out")"
grep -q "captain inbox note" "$dir/watch.out" || fail "the surfaced cycle lost the inbox note reason: $(cat "$dir/watch.out")"
pass "a local wake append kicks a waiting watcher and surfaces the note at once"

# Control: the same setup with the kick disabled must NOT surface inside the
# measurement window; the durable queue and the poll still own delivery.
dir2=$(make_case nudge-slow)
state2="$dir2/state"
pid2=$(start_watcher "$dir2" "$dir2/watch.out" 30)
sleep 2
kill -0 "$pid2" 2>/dev/null || fail "the control watcher exited early: $(cat "$dir2/watch.out")"
FM_WAKE_NUDGE_DISABLE=1 FM_STATE_OVERRIDE="$state2" FM_HOME="$dir2" "$INBOX" note --source discord --external-id 1000000000000000002 "Latency control" >/dev/null 2>&1 \
  || fail "the control inbox note could not be queued"
i=0
surfaced2=0
while [ "$i" -lt 40 ]; do
  ls "$state2"/.seen-inbox-* >/dev/null 2>&1 && { surfaced2=1; break; }
  kill -0 "$pid2" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
kill "$pid2" 2>/dev/null || true
wait "$pid2" 2>/dev/null || true
[ "$surfaced2" = 0 ] || fail "a control watcher surfaced the note without the kick, so the A/B proves nothing"
pass "with the kick disabled the note waits for the poll, so the kick is what shortens it"

# ---------------------------------------------------------------------------
# 2. the latency report folds the durable markers into the five stages
# ---------------------------------------------------------------------------
dir3=$(make_case latency-report)
state3="$dir3/state"
python3 - "$state3" <<'PY'
import datetime, hashlib, json, os, sys
state = sys.argv[1]
request_id = "discord:1:2:1000000000000000003"
messaged = "1000000000000000003"
note = "1700000000-testnote"
workspace = os.path.join(state, "discord-workspace", "conversation-console")
os.makedirs(os.path.join(workspace, "latency"), exist_ok=True)
os.makedirs(os.path.join(state, "inbox", "handled"), exist_ok=True)
base = datetime.datetime(2026, 9, 18, 12, 0, 0, tzinfo=datetime.timezone.utc).timestamp()
record = {
    "schema": "fm-discord-conversation-console.latency.v1",
    "request_id": request_id,
    "message_id": messaged,
    "channel_id": "2",
    "transport": "gateway",
    "discord_timestamp": "2026-09-18T12:00:00.000000+00:00",
    "ingested_at": base + 0.5,
    "captured_at": base + 0.7,
    "note_id": note,
    "answered_at": base + 40.0,
    "path": "full_turn",
    "updated_at": "2026-09-18T12:00:40Z",
}
name = hashlib.sha256(request_id.encode()).hexdigest() + ".json"
with open(os.path.join(workspace, "latency", name), "w", encoding="utf-8") as handle:
    json.dump(record, handle)
marker = os.path.join(state, ".seen-inbox-" + ("inbox:" + note).encode().hex())
open(marker, "w").close()
os.utime(marker, (base + 2.0, base + 2.0))
acked = os.path.join(state, "inbox", "handled", note + ".acked")
open(acked, "w").close()
os.utime(acked, (base + 5.0, base + 5.0))
PY
report=$(FM_HOME="$dir3" "$CONSOLE" latency --json 2>&1) || fail "latency failed: $report"
checked=$(printf '%s' "$report" | python3 -c '
import json, sys
row = json.load(sys.stdin)["rows"][0]
want = {"stage1_discord_to_console": 0.5, "stage2_console_handling": 0.2, "stage3_wake": 1.3, "stage4_session_activation": 3.0, "stage5_turn": 35.0, "total": 40.0}
bad = {k: (row.get(k), v) for k, v in want.items() if row.get(k) != v}
print("ok" if not bad else "bad:" + json.dumps(bad))
')
assert_equals "ok" "$checked" "the latency report computes all five stages from the durable markers"
pass "the latency report folds the watcher and inbox markers into the stages"

fm_test_cleanup
