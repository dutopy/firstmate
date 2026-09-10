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
{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-10T12:00:00Z","backlog":{"records":[{"id":"hold-1","state":"Held","hold_kind":"captain","captain_actionable":true,"hold_age_days":21,"title":"Choisir canal"},{"id":"blocked-1","state":"Queued","blocked_by_ids":["missing-1"],"title":"Bloqué"},{"id":"done-1","state":"Done","title":"Fini"}],"path":"/tmp/backlog.md"},"tasks":[{"id":"run-1","current_state":{"state":"working"},"endpoint":{"agent_alive":true}}],"secondmate_current":{"records":[]},"scout_reports":[]}
JSON
SH
chmod +x "$FAKE"
export FM_FLEET_SNAPSHOT_BIN="$FAKE"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

out=$($VIGIE --json) || fail "json digest failed"
printf '%s\n' "$out" | jq -e '.schema == "fm-vigie.v1" and (.recommendations|length)==2 and .cadence == "daily"' >/dev/null \
  || fail "json digest lacks bounded recommendations/cadence: $out"
printf '%s\n' "$out" | jq -e '[.recommendations[].action] | index("answer:hold-1") and index("unblock:blocked-1")' >/dev/null \
  || fail "recommendation actions missing: $out"
printf '%s\n' "$out" | jq -e 'all(.recommendations[]; (.reason|type)=="string" and (.evidence|type)=="array" and (.unknowns|type)=="array")' >/dev/null \
  || fail "recommendation evidence contract missing"
fr=$($VIGIE --fr) || fail "French surface failed"
printf '%s\n' "$fr" | grep -F 'Vigie quotidienne' >/dev/null || fail "French heading missing"
printf '%s\n' "$fr" | grep -F 'Répondre à hold-1' >/dev/null || fail "French action missing"
baseline="$TMP_ROOT/baseline.json"
printf '%s\n' '{"recommendations":[{"key":"answer:hold-1"}]}' > "$baseline"
event=$($VIGIE --json --event "$baseline") || fail "event digest failed"
printf '%s\n' "$event" | jq -e '.changes.new == ["unblock:blocked-1"] and .changes.resolved == []' >/dev/null \
  || fail "event delta is not deduplicated: $event"
bounded=$(FM_VIGIE_MAX=1 $VIGIE --json) || fail "bounded digest failed"
printf '%s\n' "$bounded" | jq -e '.recommendations|length == 1' >/dev/null || fail "max bound ignored"
$VIGIE --help >/dev/null || fail "help failed"
pass "bounded JSON and French recommendation surfaces"
