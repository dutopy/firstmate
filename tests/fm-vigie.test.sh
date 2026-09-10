#!/usr/bin/env bash
# Behavioral tests for the bounded native-source Vigie digest.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIGIE="$ROOT/bin/fm-vigie.sh"
SUCCESS="$ROOT/tests/fixtures/vigie/hermes-success.sh"
FAILURE="$ROOT/tests/fixtures/vigie/hermes-failure.sh"
TMP_ROOT=$(fm_test_tmproot fm-vigie)
SNAPSHOT="$TMP_ROOT/snapshot.sh"
TOOL="$TMP_ROOT/tool-update.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$SNAPSHOT" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{
  "schema":"fm-fleet-snapshot.v1",
  "generated":"2026-09-10T15:00:00Z",
  "backlog":{"present":true,"records":[
    {"id":"hold:1","state":"Held","captain_actionable":true,"hold_age_days":21,"title":"Choisir canal"},
    {"id":"blocked%1","state":"Queued","blocked_by_ids":["dep:2","dep:1","dep:1"],"title":"Bloqué","age_days":17},
    {"id":"pr:1","state":"Queued","pr_url":"https://example.test/pull/1","title":"Relire PR","age_days":20}
  ]},
  "tasks":[
    {"id":"run:1","endpoint":{"agent_alive":false,"observed_at":"2026-09-08T15:00:00Z"},"age_days":2,"hints":{"open_decisions":[{"key":"client:1","summary":"Choisir le canal","age_days":16}]}}
  ],
  "secondmate_current":{"records":[{"id":"mate:1","decisions_open":[{"key":"scope:1","summary":"Choisir le scope","hold_age_days":15}]}]},
  "client_gates":[{"id":"gate:1","title":"Valider client","status":"pending","due":"2026-09-01","age_days":20}],
  "credential_evidence":[{"id":"gh:main","source":"GitHub","status":"unknown","observed_at":"2026-09-09T00:00:00Z","age_days":1,"secret":"must-not-leak"}],
  "pending_services":[{"id":"update:1","title":"Décider mise à jour","status":"pending","reason":"release","age_days":20}]
}'
SH
cat > "$TOOL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"alerts":[{"tool_id":"hermes:agent","installed_version":"1.0","available_version":"1.1","status":"update_available","observed_at":"2026-09-10T14:00:00Z"}]}'
SH
chmod +x "$SNAPSHOT" "$TOOL" "$SUCCESS" "$FAILURE"

run_vigie() {
  HERMES_KANBAN_TASK='task:1' \
  FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" \
  FM_VIGIE_HERMES_BIN="$SUCCESS" \
  FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" \
  FM_VIGIE_NOW='2026-09-10T15:00:00Z' \
  "$VIGIE" "$@"
}

out=$(run_vigie --json) || fail "native success digest failed"
printf '%s\n' "$out" | jq -e '
  .schema == "fm-vigie.v1" and .generated == "2026-09-10T15:00:00Z" and
  .recommendation_total == (.observed_keys | length) and
  (.native | keys | length) == 12 and
  .native["hermes.kanban.stats"].status == "observed" and
  .native["firstmate.dossier"].reason_code == "no_registered_reader" and
  .native["firstmate.reflex"].reason_code == "no_registered_reader" and
  (all(.observations[]; has("key") and has("category") and has("status") and has("source_id") and has("source_identity") and has("age_days") and has("observed_at") and (.evidence|type)=="array" and (.unknowns|type)=="array"))
' >/dev/null || fail "native source-run or observation schema is incomplete: $out"
printf '%s\n' "$out" | jq -e '
  (.observed_keys | index("pr:pr%3A1")) and
  (.observed_keys | index("decision:task:run%3A1:client%3A1")) and
  (.observed_keys | index("decision:secondmate:mate%3A1:scope%3A1")) and
  (.observed_keys | index("blocked:blocked%251")) and
  (.observed_keys | index("cron:job%3A1:missing_script")) and
  (.observed_keys | index("tool-update:hermes%3Aagent")) and
  ([.observations[] | select(.key=="kanban:ready")][0].age_days == 3)
' >/dev/null || fail "stable identities or authoritative age evidence missing: $out"
printf '%s\n' "$out" | grep -F 'must-not-leak' >/dev/null && fail "credential secret leaked"

fr=$(run_vigie --fr) || fail "French surface failed"
printf '%s\n' "$fr" | grep -F 'Vigie quotidienne (' >/dev/null || fail "French heading missing"
printf '%s\n' "$fr" | grep -F 'plafond 10)' >/dev/null || fail "French cap missing"
printf '%s\n' "$fr" | grep -F 'Relire la PR pr:1 : Relire PR, âge : 20 j' >/dev/null || fail "French PR template missing"
printf '%s\n' "$fr" | grep -F 'Débloquer blocked%1 : dépend de dep:1, dep:2, âge : 17 j' >/dev/null || fail "French blocker template missing"
printf '%s\n' "$fr" | grep -F 'Livraison : pilote approuvé uniquement ; bureau futur non activé ; planification désactivée.' >/dev/null || fail "French footer missing"
fr_all=$(FM_VIGIE_MAX=50 run_vigie --fr) || fail "complete French surface failed"
for label in "Relire la PR" "Traiter l’étape client" "Décider" "Vérifier les éléments d’accès" "Résoudre l’attente" "Répondre au blocage capitaine" "Débloquer" "Inspecter le worker" "Examiner la file Kanban"; do
  printf '%s\n' "$fr_all" | grep -F -- "$label" >/dev/null || fail "French category template missing: $label"
done

baseline="$TMP_ROOT/baseline.json"
printf '%s\n' "$out" | jq '.observed_keys += ["credential:doctor:retired"] | .recommendations = [.recommendations[0]]' > "$baseline"
event=$(FM_VIGIE_MAX=1 run_vigie --json --daily --event "$baseline") || fail "bounded event digest failed"
printf '%s\n' "$event" | jq -e '
  .recommendations|length == 1
' >/dev/null || fail "display cap ignored"
printf '%s\n' "$event" | jq -e '
  .recommendation_total > 1 and
  (.changes.resolved | index("credential:doctor:retired")) and
  (.changes.resurfaced | index("pr:pr%3A1")) and
  (.observed_keys | index("pr:pr%3A1"))
' >/dev/null || fail "uncapped deltas or age resurfacing are wrong: $event"

indeterminate_baseline="$TMP_ROOT/indeterminate.json"
printf '%s\n' '{"observed_keys":["credential:doctor:minimax-oauth"],"recommendations":[{"key":"credential:doctor:minimax-oauth","evidence":[{"source_id":"hermes.doctor"}]}]}' > "$indeterminate_baseline"
indeterminate=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json --event "$indeterminate_baseline") || fail "indeterminate-source digest failed"
printf '%s\n' "$indeterminate" | jq -e '.changes.resolved == [] and ([.changes.indeterminate[].key] | index("credential:doctor:minimax-oauth"))' >/dev/null || fail "unavailable current source falsely resolved a prior key"

source_capped=$(FM_VIGIE_SOURCE_RECORD_MAX=1 run_vigie --json) || fail "source-record capped digest failed"
printf '%s\n' "$source_capped" | jq -e '([.observations[] | select(.source_id=="firstmate.fleet_snapshot" and .category=="ready_pr")] | length)==0 and ([.observations[] | select(.source_id=="firstmate.fleet_snapshot" and .category=="captain_hold")] | length)==1' >/dev/null || fail "source record cap ignored"

UNKNOWN="$TMP_ROOT/unknown.sh"
cat > "$UNKNOWN" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-10T15:00:00Z","backlog":{"present":false},"tasks":[]}'
SH
chmod +x "$UNKNOWN"
unknown=$(FM_FLEET_SNAPSHOT_BIN="$UNKNOWN" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN=/missing HERMES_KANBAN_TASK='' "$VIGIE" --json) || fail "unknown digest failed"
printf '%s\n' "$unknown" | jq -e '
  .inventory.ready_prs.status == "unknown" and
  .inventory.client_gates.status == "unknown" and
  .inventory.keyed_decisions.status == "unknown" and
  .native["hermes.kanban.task"].reason_code == "task_id_not_supplied" and
  .native["firstmate.watched_tools"].reason_code == "command_missing"
' >/dev/null || fail "absent evidence was not preserved as unknown/unavailable: $unknown"

EMPTY="$TMP_ROOT/empty.sh"
cat > "$EMPTY" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-10T15:00:00Z","backlog":{"present":true,"records":[]},"tasks":[],"secondmate_current":{"records":[]},"ready_prs":[],"client_gates":[],"credential_evidence":[],"pending_services":[]}'
SH
chmod +x "$EMPTY"
empty=$(FM_FLEET_SNAPSHOT_BIN="$EMPTY" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK='' "$VIGIE" --json) || fail "empty digest failed"
printf '%s\n' "$empty" | jq -e '.inventory.ready_prs.status == "empty" and .inventory.client_gates.status == "empty"' >/dev/null || fail "explicit empty arrays not preserved"

missing_status=0
missing=$(FM_FLEET_SNAPSHOT_BIN=/missing FM_VIGIE_HERMES_BIN=/missing FM_VIGIE_TOOL_UPDATE_BIN=/missing "$VIGIE" --json) || missing_status=$?
[ "$missing_status" -ne 0 ] || fail "all-missing producers should exit nonzero"
printf '%s\n' "$missing" | jq -e 'all(.native[]; .status == "unavailable" or .status == "unknown")' >/dev/null || fail "missing producers not unavailable"

nonzero=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json) || fail "nonzero-source digest failed"
printf '%s\n' "$nonzero" | jq -e '.native["hermes.doctor"].reason_code == "nonzero_exit" and .native["hermes.doctor"].exit_code == 7 and (.native["hermes.doctor"].stdout|contains("stdout")) and (.native["hermes.doctor"].stderr|contains("stderr"))' >/dev/null || fail "nonzero source provenance missing"

timed=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing FM_VIGIE_NATIVE_TIMEOUT=1 VIGIE_FIXTURE_FAILURE=timeout "$VIGIE" --json) || fail "timeout-source digest failed"
printf '%s\n' "$timed" | jq -e '.native["hermes.doctor"].reason_code == "timeout" and .native["hermes.doctor"].timed_out' >/dev/null || fail "timeout source provenance missing"

invalid=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing VIGIE_FIXTURE_FAILURE=invalid-json "$VIGIE" --json) || fail "invalid-json source digest failed"
printf '%s\n' "$invalid" | jq -e '.native["hermes.kanban.stats"].reason_code == "invalid_json"' >/dev/null || fail "invalid JSON provenance missing"

oversized_status=0
oversized=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing FM_VIGIE_NATIVE_MAX_BYTES=64 VIGIE_FIXTURE_FAILURE=oversized "$VIGIE" --json) || oversized_status=$?
[ "$oversized_status" -ne 0 ] || fail "all-truncated producers should exit nonzero"
printf '%s\n' "$oversized" | jq -e '.native["hermes.doctor"].stdout_truncated and (.native["hermes.doctor"].stdout|length)==64 and .native["hermes.doctor"].status == "unknown"' >/dev/null || fail "native byte cap missing"

$VIGIE --help >/dev/null || fail "help failed"
before=$(sha256sum "$SNAPSHOT" "$SUCCESS" "$TOOL")
files_before=$(find "$TMP_ROOT" -type f -printf '%P\n' | sort)
run_vigie --json --event "$baseline" >/dev/null || fail "repeat read-only digest failed"
after=$(sha256sum "$SNAPSHOT" "$SUCCESS" "$TOOL")
files_after=$(find "$TMP_ROOT" -type f -printf '%P\n' | sort)
[ "$before" = "$after" ] || fail "digest mutated fixture input"
[ "$files_before" = "$files_after" ] || fail "digest created files in fixture tree"

pass "verified native-source JSON, failure, delta, French, and read-only surfaces"
