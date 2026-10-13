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
Discord note body.
EOF
)
assert_contains "$out2" "queued $first_id" "replay returns the first note id"
[ "$(note_count)" = 1 ] || fail "replay created a duplicate note"
[ "$(wake_count)" = 1 ] || fail "replay created a duplicate wake"
pass "external-source replay is idempotent"

bad_status=0
FM_HOME="$HOME1" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id 'discord:bad/slash' - <<< 'bad' >/dev/null 2>&1 || bad_status=$?
[ "$bad_status" -ne 0 ] || fail "invalid external id was accepted"
pass "external source ids are validated before queuing"

note_count_for() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}
HOME2="$TMP_ROOT/home2"
mkdir -p "$HOME2/state" "$HOME2/data"
EXT_ID2=discord:111111111111111111:222222222222222222:888888888888888777
mkdir "$HOME2/state/.wake-queue.seq"
fail_status=0
fail_out=$(FM_HOME="$HOME2" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id "$EXT_ID2" - 2>&1 <<'WAKENOTE'
Note whose announcement will fail.
WAKENOTE
) || fail_status=$?
[ "$fail_status" -ne 0 ] || fail "announcement failure did not report failure"
[ "$(note_count_for "$HOME2")" = 1 ] || fail "failed announcement lost or duplicated the note"
fail_id=$(printf '%s\n' "$fail_out" | awk '/^queued / { print $2; exit }')
[ -n "$fail_id" ] || fail "could not parse the note id from the failed announcement"
map_file=$(python3 - "$HOME2" "$EXT_ID2" <<'PY2'
import hashlib, sys
home, ext = sys.argv[1], sys.argv[2]
digest = hashlib.sha256(f"discord-workspace:{ext}".encode()).hexdigest()
print(f"{home}/state/inbox/external/{digest}.map")
PY2
)
assert_present "$map_file" "failed announcement keeps its external map"
assert_grep "announced=0" "$map_file" "failed announcement records announced=0 in the map"
assert_grep "note_id=$fail_id" "$map_file" "failed announcement map keeps the original note id"
rmdir "$HOME2/state/.wake-queue.seq"
replay_out=$(FM_HOME="$HOME2" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id "$EXT_ID2" - <<'WAKENOTE'
Note whose announcement will fail.
WAKENOTE
)
assert_contains "$replay_out" "queued $fail_id" "replay after failed announcement returns the original note id"
[ "$(note_count_for "$HOME2")" = 1 ] || fail "replay after failed announcement created a duplicate note"
[ "$(awk 'END { print NR + 0 }' "$HOME2/state/.wake-queue" 2>/dev/null)" = 1 ] || fail "replay produced the wrong wake count"
assert_grep "announced=1" "$map_file" "delivered retry marks the map announced=1"
pass "replay after a failed announcement re-announces the original note instead of duplicating"

changed_status=0
FM_HOME="$HOME1" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id discord:111111111111111111:222222222222222222:999999999999999999 \
  --metadata-file "$META" - <<< 'Changed body.' >/dev/null 2>&1 || changed_status=$?
[ "$changed_status" -ne 0 ] || fail "an external id accepted a changed body"
[ "$(note_count)" = 1 ] || fail "changed replay created another note"
[ "$(wake_count)" = 1 ] || fail "changed replay created another wake"
pass "external id is bound to its original body"

printf '{"profile":"different","message_id":"999999999999999999"}\n' > "$META"
changed_status=0
FM_HOME="$HOME1" "$ROOT/bin/fm-inbox.sh" note \
  --source discord-workspace \
  --external-id discord:111111111111111111:222222222222222222:999999999999999999 \
  --metadata-file "$META" - <<< 'Discord note body.' >/dev/null 2>&1 || changed_status=$?
[ "$changed_status" -ne 0 ] || fail "an external id accepted changed metadata"
python3 - "$metadata_copy" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["profile"] == "proapplis"
PY
pass "changed metadata rejects without overwriting the original"

HOME3="$TMP_ROOT/home3"
FAULT_BIN="$TMP_ROOT/fault-bin"
mkdir -p "$HOME3/state" "$HOME3/data" "$FAULT_BIN"
# Inject only the map-publication filesystem failure; run the real CLI and note writes.
cat > "$FAULT_BIN/mv" <<'SH'
#!/usr/bin/env bash
for last; do :; done
case "$last" in *.map) exit 97 ;; esac
exec /bin/mv "$@"
SH
chmod +x "$FAULT_BIN/mv"
crash_status=0
PATH="$FAULT_BIN:$PATH" FM_HOME="$HOME3" "$ROOT/bin/fm-inbox.sh" note \
  --source fred --external-id annotation-crash-note-01 - \
  <<< 'Synthetic browser comment.' >/dev/null 2>&1 || crash_status=$?
[ "$crash_status" -ne 0 ] || fail "map-publication failure was not reported"
[ "$(note_count_for "$HOME3")" = 1 ] || fail "publication failure lost the note"
orphan_note=$(find "$HOME3/state/inbox" -maxdepth 1 -name '*.note')
orphan_id=$(basename "$orphan_note" .note)
recovered=$(FM_HOME="$HOME3" "$ROOT/bin/fm-inbox.sh" note \
  --source fred --external-id annotation-crash-note-01 - <<< 'Synthetic browser comment.')
assert_contains "$recovered" "queued $orphan_id" "missing map recovers the published note identity"
[ "$(note_count_for "$HOME3")" = 1 ] || fail "map recovery duplicated the note"
[ "$(awk 'END { print NR + 0 }' "$HOME3/state/.wake-queue")" = 1 ] || fail "recovered note was not announced once"
pass "a crash between note and map publication recovers the exact note"

mkdir -p "$HOME3/state/inbox/handled"
mv "$orphan_note" "$HOME3/state/inbox/handled/"
map3=$(find "$HOME3/state/inbox/external" -name '*.map')
rm "$map3"
recovered=$(FM_HOME="$HOME3" "$ROOT/bin/fm-inbox.sh" note \
  --source fred --external-id annotation-crash-note-01 - <<< 'Synthetic browser comment.')
assert_contains "$recovered" "queued $orphan_id" "handled note recovers its original identity"
[ "$(note_count_for "$HOME3")" = 0 ] || fail "handled recovery requeued the note"
[ "$(awk 'END { print NR + 0 }' "$HOME3/state/.wake-queue")" = 1 ] || fail "handled recovery added a wake"
pass "handled note recovery does not requeue processed work"

rm "$map3"
cp "$HOME3/state/inbox/handled/$orphan_id.note" "$HOME3/state/inbox/$orphan_id.note"
ambiguous_status=0
FM_HOME="$HOME3" "$ROOT/bin/fm-inbox.sh" note \
  --source fred --external-id annotation-crash-note-01 - \
  <<< 'Synthetic browser comment.' >/dev/null 2>&1 || ambiguous_status=$?
[ "$ambiguous_status" -ne 0 ] || fail "ambiguous published identities were silently selected"
[ "$(note_count_for "$HOME3")" = 1 ] || fail "ambiguous recovery added another note"
pass "ambiguous external identities refuse without another publication"

HOME4="$TMP_ROOT/home4"
mkdir -p "$HOME4/state/inbox/handled" "$HOME4/data"
ln -s /nonexistent "$HOME4/state/inbox/handled/decoy.note"
printf 'id=decoy2\nexternal_source=fred\nexternal_id=fresh-id-01\n--\nother\n' > "$HOME4/state/inbox/decoy2.note"
fresh=$(FM_HOME="$HOME4" "$ROOT/bin/fm-inbox.sh" note \
  --source fred --external-id fresh-id-01 - <<< 'Fresh body.')
assert_contains "$fresh" "queued ext-" "fresh external id publishes under its digest-derived note id"
[ -f "$HOME4/state/inbox/$(printf '%s' "$fresh" | sed -n '1s/^queued //p').note" ] || fail "digest-derived note was not published"
pass "fresh external ids do not scan unrelated pending or handled notes"

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import concurrent.futures, os, pathlib, subprocess, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
home = temporary / "concurrent-home"
home.mkdir(mode=0o700)
env = dict(os.environ, FM_HOME=str(home), FM_WAKE_NUDGE_DISABLE="1")
for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
    env.pop(key, None)
command = [str(root / "bin/fm-inbox.sh"), "note", "--source", "fred",
           "--external-id", "annotation-concurrent-01", "-"]
body = b"First line.\r\nSecond line.\n"
def submit(_):
    result = subprocess.run(command, input=body, env=env, capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    return result.stdout.splitlines()[0]
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    receipts = list(pool.map(submit, range(16)))
assert len(set(receipts)) == 1, receipts
notes = list((home / "state/inbox").glob("*.note"))
assert len(notes) == 1
assert (home / "state/.wake-queue").read_bytes().count(b"\n") == 1
assert notes[0].read_bytes().partition(b"\n--\n")[2] == body

home = temporary / "crash-metadata-home"
home.mkdir(mode=0o700)
env["FM_HOME"] = str(home)
metadata = temporary / "crash-metadata.json"
metadata.write_text('{"batch":"original"}\n')
command = [str(root / "bin/fm-inbox.sh"), "note", "--source", "fred",
           "--external-id", "annotation-crash-metadata-01", "--metadata-file", str(metadata), "-"]
fault_env = dict(env, PATH=str(temporary / "fault-bin") + ":" + env["PATH"])
failed = subprocess.run(command, input=b"Immutable annotation.\n", env=fault_env, capture_output=True)
assert failed.returncode != 0
notes = list((home / "state/inbox").glob("*.note"))
assert len(notes) == 1
original_note = notes[0].read_bytes()
copied = next((home / "state/inbox/external").glob("*.metadata.json"))
original_metadata = copied.read_bytes()
metadata.write_text('{"batch":"changed"}\n')
changed = subprocess.run(command, input=b"Immutable annotation.\n", env=env, capture_output=True)
assert changed.returncode != 0
assert copied.read_bytes() == original_metadata
assert notes[0].read_bytes() == original_note
assert not list((home / "state/inbox/external").glob("*.map"))
metadata.write_bytes(original_metadata)
recovered = subprocess.run(command, input=b"Immutable annotation.\n", env=env, capture_output=True)
assert recovered.returncode == 0, recovered.stderr.decode()
assert recovered.stdout.splitlines()[0] == ("queued " + notes[0].stem).encode()
assert len(list((home / "state/inbox").glob("*.note"))) == 1
PY
pass "concurrent CRLF replays retain one exact note and receipt"
pass "lost-map changed metadata cannot overwrite the immutable captured payload"
