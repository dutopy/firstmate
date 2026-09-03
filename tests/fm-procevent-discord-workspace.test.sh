#!/usr/bin/env bash
# Behavior tests for the Discord workspace process-event adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-discord-workspace-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
HOME1="$TMP_ROOT/home1"
HOME2="$TMP_ROOT/home2"
HOME3="$TMP_ROOT/home3"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
ped() { FM_HOME="$1" "$ROOT/bin/fm-procevent-discord-workspace.sh" "${@:2}"; }

cleanup_procevent_discord() {
  pe "$HOME1" sweep-home >/dev/null 2>&1 || true
  pe "$HOME2" sweep-home >/dev/null 2>&1 || true
  pe "$HOME3" sweep-home >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_procevent_discord EXIT

make_config() {
  local home=$1 cfg=$2
  mkdir -p "$home/state" "$home/data" "$home/config"
  chmod 700 "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-discord-workspace.sh" sample-config > "$cfg"
  python3 - "$cfg" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["proapplis"]["thread_ids"]["exchange"]=["888888888888888881"]
data["transcription"]["provider"]="fake"
data["transcription"]["fake_transcripts"]={
  "999999999999999998":"transcribed voice fixture",
  "999999999999999996":"transcribed upload fixture"
}
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
}

note_count() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

wake_count() {
  awk 'END { print NR + 0 }' "$1/state/.wake-queue" 2>/dev/null
}

wake_payloads() {
  awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null
}

first_note() {
  local home=$1
  for f in "$home/state/inbox"/*.note; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

result_path() {
  local home=$1 seq=$2
  printf '%s/state/procevent-inbox/discord-workspace.%s.result\n' "$home" "$seq"
}

CFG1="$HOME1/config/discord-workspace.json"
make_config "$HOME1" "$CFG1"
FIXTURE1="$TMP_ROOT/messages.json"
cat > "$FIXTURE1" <<'JSON'
{
  "messages": [
    {"id":"999999999999999991","channel_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"direct message without a guild"},
    {"id":"999999999999999992","guild_id":"121212121212121212","channel_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"wrong guild"},
    {"id":"999999999999999993","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"333333333333333333","bot":true},"content":"bot message"},
    {"id":"999999999999999994","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"454545454545454545"},"content":"wrong author"},
    {"id":"999999999999999995","guild_id":"111111111111111111","channel_id":"555555555555555553","author":{"id":"444444444444444444"},"content":"artifact forum input"},
    {"id":"999999999999999996","guild_id":"111111111111111111","channel_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"forum root input without an allowlisted thread"},
    {"id":"999999999999999997","guild_id":"111111111111111111","channel_id":"888888888888888881","parent_id":"555555555555555552","author":{"id":"444444444444444444"},"content":"Thread text request."}
  ]
}
JSON

out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE1" ped "$HOME1" source --config "$CFG1")
assert_contains "$out" "Thread text request" "source returns the first allowlisted exchange-thread message"
assert_not_contains "$out" "wrong guild" "source skips unknown guilds"
printf '%s\n' "$out" > "$TMP_ROOT/result.json"
class=$(ped "$HOME1" classify "$TMP_ROOT/result.json")
assert_contains "$class" "message" "classify identifies accepted text messages"
if ped "$HOME1" silent "$TMP_ROOT/result.json" >/dev/null 2>&1; then
  fail "accepted text message was classified silent"
fi
pass "source enforces guild, channel, author, bot, and forum allowlists"

nofixture_status=0
nofixture_out=$(ped "$HOME1" source --config "$CFG1" 2>&1) || nofixture_status=$?
[ "$nofixture_status" -ne 0 ] || fail "source without fixture succeeded"
assert_contains "$nofixture_out" "no network call" "source without fixture refuses before network"
out=$(ped "$HOME1" arm --dry-run --config "$CFG1")
assert_contains "$out" "arm dry-run" "arm dry-run is explicit"
assert_contains "$out" "register command" "arm dry-run prints the registration command"
arm_status=0
arm_out=$(ped "$HOME1" arm --config "$CFG1" 2>&1) || arm_status=$?
[ "$arm_status" -ne 0 ] || fail "non-dry-run arm was accepted"
assert_contains "$arm_out" "offline phase" "non-dry-run arm refuses while inactive"
pass "process-event arming remains offline unless a later live task activates it"

pe "$HOME1" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG1" >/dev/null
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE1" pe "$HOME1" start discord-workspace)
assert_contains "$out" "autohandled" "process-event start autohandles accepted Discord messages"
assert_present "$(result_path "$HOME1" 1)" "first captured Discord result exists"
assert_present "$HOME1/state/procevent-inbox/discord-workspace.1.handled" "autohandle records the process-event acknowledgement"
[ "$(note_count "$HOME1")" = 1 ] || fail "autohandle created the wrong inbox note count"
[ "$(wake_count "$HOME1")" = 1 ] || fail "autohandle created the wrong wake count"
assert_contains "$(wake_payloads "$HOME1")" "captain inbox note" "accepted Discord event announces through the inbox"
assert_not_contains "$(wake_payloads "$HOME1")" "procevent discord-workspace" "self-announcing adapter suppresses duplicate process-event wake"
NOTE=$(first_note "$HOME1") || fail "autohandle did not create an inbox note"
assert_grep "Discord workspace / proapplis / text" "$NOTE" "note body identifies Discord text intake"
assert_grep "Thread text request." "$NOTE" "note body preserves the captain text"
ack_out=$(pe "$HOME1" handled discord-workspace 1)
assert_contains "$ack_out" "already-handled" "process-event acknowledgement is idempotent"
pass "accepted Discord process-event creates one inbox notification and one handled marker"

rm -f "$HOME1/state/discord-workspace/cursors/proapplis/888888888888888881.cursor"
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE1" pe "$HOME1" start discord-workspace)
assert_contains "$out" "autohandled" "replayed fixture is still handled"
assert_present "$HOME1/state/procevent-inbox/discord-workspace.2.handled" "replayed fixture is acknowledged"
[ "$(note_count "$HOME1")" = 1 ] || fail "replayed Discord message created a duplicate inbox note"
[ "$(wake_count "$HOME1")" = 1 ] || fail "replayed Discord message created a duplicate inbox wake"
pass "Discord process-event replay deduplicates through fm-inbox external ids"

CFG2="$HOME2/config/discord-workspace.json"
make_config "$HOME2" "$CFG2"
FIXTURE2="$TMP_ROOT/voice.json"
cat > "$FIXTURE2" <<'JSON'
{
  "messages": [
    {
      "id":"999999999999999998",
      "guild_id":"111111111111111111",
      "channel_id":"888888888888888881",
      "parent_id":"555555555555555552",
      "author":{"id":"444444444444444444"},
      "content":"Voice context.",
      "flags":8192,
      "attachments":[{"id":"101010101010101010","filename":"voice.ogg","content_type":"audio/ogg","size":1024,"duration_secs":12,"url":"https://cdn.discordapp.com/attachments/1/voice.ogg"}]
    }
  ]
}
JSON
pe "$HOME2" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG2" >/dev/null
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE2" pe "$HOME2" start discord-workspace)
assert_contains "$out" "autohandled" "voice fixture is autohandled"
NOTE2=$(first_note "$HOME2") || fail "voice fixture did not create a note"
assert_grep "voice transcript" "$NOTE2" "voice note is identified as a transcript"
assert_grep "transcribed voice fixture" "$NOTE2" "fake transcription is used for voice fixtures"
assert_grep "transcription: fake fixture, no secret" "$NOTE2" "voice note does not print provider secrets"
assert_not_contains "$(cat "$NOTE2")" "FIRSTMATE_DISCORD_GROQ_API_KEY" "voice note does not leak secret key names"
pass "voice-message fixtures validate audio and produce safe transcript notes"

CFG3="$HOME3/config/discord-workspace.json"
make_config "$HOME3" "$CFG3"
FIXTURE3="$TMP_ROOT/bad-audio.json"
cat > "$FIXTURE3" <<'JSON'
{
  "messages": [
    {
      "id":"999999999999999996",
      "guild_id":"111111111111111111",
      "channel_id":"888888888888888881",
      "parent_id":"555555555555555552",
      "author":{"id":"444444444444444444"},
      "flags":8192,
      "attachments":[{"id":"202020202020202020","filename":"voice.ogg","content_type":"audio/ogg","size":1024,"duration_secs":12,"url":"https://evil.example.invalid/voice.ogg"}]
    }
  ]
}
JSON
pe "$HOME3" register discord-workspace discord-workspace -- \
  "$ROOT/bin/fm-procevent-discord-workspace.sh" source --config "$CFG3" >/dev/null
out=$(FM_DISCORD_WORKSPACE_FIXTURE="$FIXTURE3" pe "$HOME3" start discord-workspace)
assert_contains "$out" "autohandled" "bad audio rejection is autohandled"
NOTE3=$(first_note "$HOME3") || fail "bad audio fixture did not create an error note"
assert_grep "audio rejected" "$NOTE3" "bad audio creates a durable rejection note"
assert_grep "Discord CDN allowlist" "$NOTE3" "bad audio refusal names the failed check"
assert_not_contains "$(cat "$NOTE3")" "do-not-print" "bad audio note does not leak secret material"
pass "audio intake rejects non-Discord CDN URLs with a durable non-secret note"
