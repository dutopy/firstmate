#!/usr/bin/env bash
# Behavioral tests for the bounded recommendation digest.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
VIGIE="$ROOT/bin/fm-vigie.sh"
TMP_ROOT=$(fm_test_tmproot fm-vigie)
FAKE="$TMP_ROOT/snapshot.sh"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-10T12:00:00Z","backlog":{"records":[{"id":"hold-1","state":"Held","hold_kind":"captain","captain_actionable":true,"hold_age_days":21,"title":"Choisir canal"},{"id":"blocked-1","state":"Queued","blocked_by_ids":["missing-1"],"title":"Bloqué"},{"id":"pr-1","state":"Queued","pr_url":"https://example.test/pull/1","title":"Relire PR"},{"id":"done-1","state":"Done","title":"Fini"}],"path":"/tmp/backlog.md"},"tasks":[{"id":"run-1","current_state":{"state":"working"},"endpoint":{"agent_alive":true},"hints":{"open_decisions":[{"key":"client-1","summary":"Choisir le canal"}]}}],"secondmate_current":{"records":[]},"client_gates":[{"id":"gate-1","title":"Valider client","reason":"Attente client","age_days":20}],"credential_evidence":[{"id":"gh","source":"GitHub","status":"unknown","reason":"Evidence unavailable"}],"pending_services":[{"id":"update-1","title":"Décider mise à jour","age_days":20}],"scout_reports":[]}
JSON
SH
chmod +x "$FAKE"
export FM_FLEET_SNAPSHOT_BIN="$FAKE"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

out=$($VIGIE --json) || fail "json digest failed"
printf '%s\n' "$out" | jq -e '.schema == "fm-vigie.v1" and (.recommendations|length)==7 and .cadence == "daily"' >/dev/null \
  || fail "json digest lacks bounded recommendations/cadence: $out"
printf '%s\n' "$out" | jq -e '[.recommendations[].action] | index("answer:hold-1") and index("unblock:blocked-1")' >/dev/null \
  || fail "recommendation actions missing: $out"
printf '%s\n' "$out" | jq -e '.inventory.ready_prs.count == 1 and .inventory.client_gates.count == 1 and .inventory.credential_evidence.count == 1 and .inventory.pending_service_updates.count == 1 and ([.recommendations[].action] | index("decide:client-1"))' >/dev/null \
  || fail "source-backed recommendation inventory missing: $out"
printf '%s\n' "$out" | jq -e 'all(.recommendations[]; (.reason|type)=="string" and (.evidence|type)=="array" and (.unknowns|type)=="array")' >/dev/null \
  || fail "recommendation evidence contract missing"
fr=$($VIGIE --fr) || fail "French surface failed"
printf '%s\n' "$fr" | grep -F 'Vigie quotidienne' >/dev/null || fail "French heading missing"
printf '%s\n' "$fr" | grep -F 'Répondre à hold-1' >/dev/null || fail "French action missing"
baseline="$TMP_ROOT/baseline.json"
printf '%s\n' '{"recommendations":[{"key":"answer:hold-1"}]}' > "$baseline"
event=$($VIGIE --json --event "$baseline") || fail "event digest failed"
printf '%s\n' "$event" | jq -e '(.changes.new | index("unblock:blocked-1")) and .changes.resolved == []' >/dev/null \
  || fail "event delta is not deduplicated: $event"
daily=$($VIGIE --json --daily --event "$baseline") || fail "daily digest failed"
printf '%s\n' "$daily" | jq -e '.cadence == "daily" and (.changes.resurfaced | index("answer:hold-1"))' >/dev/null \
  || fail "daily aged resurfacing missing: $daily"
bounded=$(FM_VIGIE_MAX=1 $VIGIE --json) || fail "bounded digest failed"
printf '%s\n' "$bounded" | jq -e '.recommendations|length == 1' >/dev/null || fail "max bound ignored"
$VIGIE --help >/dev/null || fail "help failed"
before=$(sha256sum "$FAKE" | awk '{print $1}')
$VIGIE --json >/dev/null || fail "repeat read-only digest failed"
after=$(sha256sum "$FAKE" | awk '{print $1}')
[ "$before" = "$after" ] || fail "digest mutated its source"
pass "bounded JSON and French recommendation surfaces"
