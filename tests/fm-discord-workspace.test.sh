#!/usr/bin/env bash
# Behavior tests for private Discord workspace planning, receipts, and artifacts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-workspace-tests)
HOME1="$TMP_ROOT/home"
mkdir -p "$HOME1/state" "$HOME1/data" "$HOME1/config" "$HOME1/projects"
CFG="$HOME1/config/discord-workspace.json"
FM_HOME="$HOME1" "$ROOT/bin/fm-discord-workspace.sh" sample-config > "$CFG"
python3 - "$CFG" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["proapplis"]["thread_ids"]["exchange"]=["888888888888888881"]
data["profiles"]["proapplis"]["thread_ids"]["artifacts"]=["888888888888888882"]
data["transcription"]["provider"]="fake"
data["transcription"]["fake_transcripts"]={"999999999999999998":"transcribed voice fixture"}
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY

fw() { FM_HOME="$HOME1" "$ROOT/bin/fm-discord-workspace.sh" "$@"; }
request_id='discord:111111111111111111:888888888888888881:999999999999999999'
thread_request_id='discord:111111111111111111:888888888888888881:999999999999999997'

out=$(fw config-check --config "$CFG")
assert_contains "$out" "config ok" "valid config passes"
assert_contains "$out" "ProApplis: exchange threads 1" "thread allowlist is reported"
pass "valid non-secret config is accepted"

DUP="$TMP_ROOT/duplicate.json"
cp "$CFG" "$DUP"
python3 - "$DUP" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["folium"]["exchange_forum_id"]=data["profiles"]["proapplis"]["exchange_forum_id"]
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
dup_status=0
dup_out=$(fw config-check --config "$DUP" 2>&1) || dup_status=$?
[ "$dup_status" -ne 0 ] || fail "duplicate forum id was accepted"
assert_contains "$dup_out" "duplicate Discord id" "duplicate forum id refusal is explicit"

PLACEHOLDER="$TMP_ROOT/placeholder.json"
cp "$CFG" "$PLACEHOLDER"
python3 - "$PLACEHOLDER" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["profiles"]["example-client"]={"enabled": False}
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
placeholder_status=0
placeholder_out=$(fw config-check --config "$PLACEHOLDER" 2>&1) || placeholder_status=$?
[ "$placeholder_status" -ne 0 ] || fail "dormant profile placeholder was accepted"
assert_contains "$placeholder_out" "unsupported profile(s): example-client" "profile placeholder refusal is explicit"

SECRET="$TMP_ROOT/secret.json"
cp "$CFG" "$SECRET"
python3 - "$SECRET" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["bot_token"]="do-not-print-this-value"
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
secret_status=0
secret_out=$(fw config-check --config "$SECRET" 2>&1) || secret_status=$?
[ "$secret_status" -ne 0 ] || fail "inline secret-looking config was accepted"
assert_contains "$secret_out" "inline secret" "inline secret refusal is explicit"
assert_not_contains "$secret_out" "do-not-print-this-value" "secret-looking value is not printed"
pass "config rejects duplicate channels, profile placeholders, and inline secrets"

out=$(fw setup --dry-run --config "$CFG")
assert_contains "$out" "no network" "setup dry-run says it is offline"
assert_contains "$out" "temporary setup permission integer" "setup dry-run prints setup permissions"
assert_contains "$out" "steady-state permission integer" "setup dry-run prints steady permissions"
assert_contains "$out" "profile System / Firstmate" "setup dry-run names the system category"
assert_contains "$out" "profile ProApplis" "setup dry-run names the ProApplis category"
assert_contains "$out" "profile Folium" "setup dry-run names the Folium category"
assert_contains "$out" "exchanges forum" "setup dry-run names exchange forums"
assert_contains "$out" "artifacts forum" "setup dry-run names artifact forums"
assert_contains "$out" "request, decision, work, status, blocked, done" "setup dry-run prints exchange tags"
assert_contains "$out" "report, board, document, image, audio, draft, final, expired" "setup dry-run prints artifact tags"
assert_contains "$out" "remaining unapproved live choices" "setup dry-run reports inactive live choices"
apply_status=0
apply_out=$(fw setup --apply --config "$CFG" 2>&1) || apply_status=$?
[ "$apply_status" -ne 0 ] || fail "setup --apply was accepted"
assert_contains "$apply_out" "not available" "setup --apply refuses in phase one"

LIVECHOICES="$TMP_ROOT/live-choices.json"
cp "$CFG" "$LIVECHOICES"
python3 - "$LIVECHOICES" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p))
data["approvals"]["message_content"]=True
data["approvals"]["temporary_setup_permissions"]=True
data["approvals"]["hosted_groq"]=True
data["approvals"]["community_mode_required"]=True
data["live"]={"polling": True, "posting": True, "host": "omarchy"}
data["outbound"]["live_posting"]=True
data["artifacts"]["access"]="tailnet"
data["artifacts"]["default_expiry"]="3d"
data["transcription"]["provider"]="groq"
json.dump(data, open(p,"w"), indent=2, sort_keys=True)
PY
out=$(fw setup --dry-run --config "$LIVECHOICES")
assert_contains "$out" "Discord MESSAGE_CONTENT is configured but inactive" "message content remains inert when configured"
assert_contains "$out" "host omarchy is configured but not activated" "host choice remains inert when configured"
assert_contains "$out" "hosted Groq transcription is configured but inactive" "hosted Groq remains inert when configured"
assert_contains "$out" "artifact access tailnet with expiry 3d is configured but inactive" "artifact access remains inert when configured"
assert_contains "$out" "temporary setup permissions are configured but unusable" "temporary setup permissions remain inert when configured"
assert_contains "$out" "live posting is configured but refused" "live posting remains inert when configured"
assert_contains "$out" "live process-event polling is configured but refused" "live polling remains inert when configured"
pass "setup planning is explicit, live choices stay inert, and apply mode refuses"

health_status=0
health_out=$(FMX_PAIRING_TOKEN='do-not-print-this-value' fw health --secrets --config "$CFG" 2>&1) || health_status=$?
[ "$health_status" -ne 0 ] || fail "live secret health unexpectedly succeeded"
assert_contains "$health_out" "no secret was decrypted or printed" "secret health reports the privacy boundary"
assert_not_contains "$health_out" "do-not-print-this-value" "secret health never prints ambient secrets"
discord_status=0
discord_out=$(fw health --discord --config "$CFG" 2>&1) || discord_status=$?
[ "$discord_status" -ne 0 ] || fail "live Discord health unexpectedly succeeded"
assert_contains "$discord_out" "no network call" "Discord health refuses without network"
pass "health checks stay dry-run only"

TEXT="$TMP_ROOT/reply.txt"
printf 'Reply text for Discord.\n' > "$TEXT"
out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT")
assert_contains "$out" "Discord reply plan" "reply renders a dry-run plan"
assert_contains "$out" '"parse": []' "reply disables mentions"
assert_contains "$out" "no Discord post was made" "reply dry-run avoids posting"
out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT" --record-discord-message-id 123456789012345678)
assert_contains "$out" "receipt recorded" "reply receipt is recorded"
out=$(fw reply --config "$CFG" --request-id "$request_id" --text-file "$TEXT" --record-discord-message-id 123456789012345678)
assert_contains "$out" "receipt exists" "reply receipt deduplicates retries"
receipt_count=$(find "$HOME1/state/discord-workspace/receipts" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$receipt_count" = 1 ] || fail "receipt retry created duplicate receipts"
pass "outbound reply receipts are idempotent"

out=$(fw link-task discord-task --config "$CFG" --request-id "$thread_request_id")
assert_contains "$out" "request record written" "link-task writes the request record"
assert_contains "$out" "task link written" "link-task writes the task link"
assert_contains "$out" "pending final follow-up written" "link-task writes a pending final follow-up"
guard_status=0
guard_out=$(fw guard-work discord-task 2>&1) || guard_status=$?
[ "$guard_status" -ne 0 ] || fail "guard-work allowed a pending final reply"
assert_contains "$guard_out" "still owes" "guard-work names the pending final reply"
out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT")
assert_contains "$out" "pending final follow-up: present" "dry-run final follow-up sees the pending record"
assert_contains "$out" "remains unresolved" "dry-run final follow-up does not clear the promise"
out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT" --record-discord-message-id 123456789012345679)
assert_contains "$out" "pending final follow-up delivered" "recorded final follow-up clears the pending state"
fw guard-work discord-task >/dev/null || fail "guard-work refused after final delivery"
out=$(fw followup discord-task --config "$CFG" --final --text-file "$TEXT")
assert_contains "$out" "final follow-up already delivered" "dry-run final follow-up after delivery reports delivered status"
assert_contains "$out" "was already delivered" "dry-run final follow-up after delivery does not claim it is unresolved"
assert_not_contains "$out" "pending final follow-up: present" "dry-run final follow-up after delivery does not claim it is pending"
assert_not_contains "$out" "remains unresolved" "dry-run final follow-up after delivery does not claim it remains unresolved"
pass "request links preserve and clear pending final replies"

REPORT="$HOME1/data/report.md"
printf '# Report\n\nSafe report.\n' > "$REPORT"
out=$(fw artifact --config "$CFG" --profile proapplis --file "$REPORT" --purpose report --request-id "$request_id")
assert_contains "$out" "canonical post forum" "artifact plan names the canonical artifact forum"
assert_contains "$out" "exchange summary includes a card and link only" "artifact plan avoids duplicate binaries"
assert_contains "$out" "direct attachment in the artifacts forum only" "small artifact plan uses one direct attachment"
out=$(fw artifact --config "$CFG" --profile proapplis --file "$REPORT" --purpose report --request-id "$request_id" --record-discord-message-id 123456789012345680)
assert_contains "$out" "artifact record written" "recorded artifact writes its artifact record"
assert_contains "$out" "receipt recorded" "recorded artifact writes a receipt"
duplicate_artifact_status=0
duplicate_artifact_out=$(fw artifact --config "$CFG" --profile proapplis --file "$REPORT" --purpose final --request-id "$request_id" --record-discord-message-id 123456789012345681 2>&1) || duplicate_artifact_status=$?
[ "$duplicate_artifact_status" -ne 0 ] || fail "duplicate canonical artifact source was accepted"
assert_contains "$duplicate_artifact_out" "already has a canonical artifact" "canonical artifact source cannot be posted twice"

mkdir -p "$HOME1/projects/client"
printf '# Project report\n' > "$HOME1/projects/client/report.md"
project_status=0
project_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/projects/client/report.md" --purpose report 2>&1) || project_status=$?
[ "$project_status" -ne 0 ] || fail "project path artifact was accepted"
assert_contains "$project_out" "under projects" "project artifact refusal names the path class"

printf 'not really an image\n' > "$HOME1/data/bad.png"
mime_status=0
mime_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/bad.png" --purpose image 2>&1) || mime_status=$?
[ "$mime_status" -ne 0 ] || fail "MIME mismatch was accepted"
assert_contains "$mime_out" "PNG extension" "MIME mismatch refusal names the mismatch"

printf 'archive bytes\n' > "$HOME1/data/archive.zip"
archive_status=0
archive_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/archive.zip" --purpose document 2>&1) || archive_status=$?
[ "$archive_status" -ne 0 ] || fail "archive artifact was accepted"
assert_contains "$archive_out" "blocked" "archive refusal reports the default block"

printf 'secret bytes\n' > "$HOME1/data/api-token.txt"
secret_artifact_status=0
secret_artifact_out=$(fw artifact --config "$CFG" --profile proapplis --file "$HOME1/data/api-token.txt" --purpose document 2>&1) || secret_artifact_status=$?
[ "$secret_artifact_status" -ne 0 ] || fail "secret-looking artifact was accepted"
assert_contains "$secret_artifact_out" "blocked" "secret-looking artifact refusal reports the default block"

BIG="$HOME1/data/big.txt"
python3 - "$BIG" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"a" * (8 * 1024 * 1024 + 1))
PY
big_status=0
big_out=$(fw artifact --config "$CFG" --profile proapplis --file "$BIG" --purpose document 2>&1) || big_status=$?
[ "$big_status" -ne 0 ] || fail "oversized direct artifact was accepted"
assert_contains "$big_out" "exceeds the direct attachment cap" "oversized artifact points to private publishing"
pass "artifact planning blocks unsafe paths, MIME mismatches, archives, secrets, and oversized direct uploads"

DOCUMENT="$HOME1/data/document.md"
printf '# Document\n\nSafe document.\n' > "$DOCUMENT"
out=$(fw publish-artifact --config "$CFG" --profile proapplis --file "$DOCUMENT" --purpose document --url 'https://private.example.invalid/capability/abcdefghijklmnopqrstuvwxyz' --access tailnet --expires 7d --record)
assert_contains "$out" "Private artifact link plan" "private artifact publishing renders a plan"
assert_contains "$out" "artifact record" "private artifact publishing records metadata when asked"
pass "larger private artifact interface records expiring link metadata"

retire_status=0
retire_out=$(fw retire --config "$CFG" 2>&1) || retire_status=$?
[ "$retire_status" -eq 0 ] || fail "retire refused after pending final was delivered: $retire_out"
assert_contains "$retire_out" "retirement dry-run" "retirement stays dry-run"
pass "safe retirement preserves state and refuses no live action"
