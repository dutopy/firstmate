#!/usr/bin/env bash
# fm-vigie.sh - bounded, read-only daily/event recommendation digest.
#
# The fleet snapshot remains the authority. This command only projects its
# structured records; it never closes work, schedules notifications, or runs
# merge/auth/service/update operations. JSON is the AXI form; the default is a
# compact TOON-like projection and --fr is a concise French notification view.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="${FM_FLEET_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
HERMES="${FM_VIGIE_HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
MAX="${FM_VIGIE_MAX:-10}"
AGE_DAYS="${FM_VIGIE_AGE_DAYS:-14}"
NATIVE_TIMEOUT="${FM_VIGIE_NATIVE_TIMEOUT:-20}"
case "$MAX" in ''|*[!0-9]*|0) printf 'fm-vigie: FM_VIGIE_MAX must be a positive integer\n' >&2; exit 2 ;; esac
case "$AGE_DAYS" in ''|*[!0-9]*) printf 'fm-vigie: FM_VIGIE_AGE_DAYS must be a non-negative integer\n' >&2; exit 2 ;; esac
case "$NATIVE_TIMEOUT" in ''|*[!0-9]*|0) printf 'fm-vigie: FM_VIGIE_NATIVE_TIMEOUT must be a positive integer\n' >&2; exit 2 ;; esac

usage() {
  printf '%s\n' \
    'usage: fm-vigie.sh [--json|--fr] [--event <previous.json>] [--daily]' \
    '' \
    'Read-only bounded recommendation digest over fm-fleet-snapshot.sh.' \
    'Default output is compact AXI/TOON; --json is machine-readable; --fr is' \
    'a concise French notification view. --event compares stable observation' \
    'identities with a prior JSON digest. --daily resurfaces aged observations.' \
    'Native readers are bounded by FM_VIGIE_NATIVE_TIMEOUT (default 20 seconds).' \
    'No mode mutates work or schedules delivery.'
}

format=toon
previous=
while [ $# -gt 0 ]; do
  case "$1" in
    --json) format=json ;;
    --fr) format=fr ;;
    --daily) daily=true ;;
    --event) shift; previous=${1-} ;;
    --event=*) previous=${1#--event=} ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-vigie: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
daily=${daily:-false}
command -v jq >/dev/null 2>&1 || { printf 'fm-vigie: jq is required\n' >&2; exit 1; }
[ -x "$SNAPSHOT" ] || { printf 'fm-vigie: snapshot command is unavailable: %s\n' "$SNAPSHOT" >&2; exit 1; }
current=$($SNAPSHOT --json) || { printf 'fm-vigie: fleet snapshot failed\n' >&2; exit 1; }
printf '%s\n' "$current" | jq -e 'type == "object" and (.schema|type)=="string"' >/dev/null \
  || { printf 'fm-vigie: fleet snapshot was not structured JSON\n' >&2; exit 1; }

# These are read-only native observations, not a second ledger.  Keep the raw
# text because several Hermes readers intentionally have no JSON mode; a
# missing command is evidence of an unavailable source, never an empty result.
native_cmd() {
  local name=$1; shift
  if [ -n "$HERMES" ] && [ -x "$HERMES" ]; then
    timeout "$NATIVE_TIMEOUT" "$HERMES" "$@" 2>&1 | head -c 12000 || true
  else
    printf 'unavailable: hermes command is not installed (%s)\n' "$name"
  fi
}
native=$(jq -cn \
  --arg stats "$(native_cmd kanban-stats kanban stats --json)" \
  --arg subscriptions "$(native_cmd kanban-notify-subscribe kanban notify-list)" \
  --arg monitoring "$(native_cmd monitoring monitoring status)" \
  --arg insights "$(native_cmd insights insights --days 1)" \
  --arg doctor "$(native_cmd doctor doctor)" \
  --arg cron "$(native_cmd cron-list cron list)" \
  --arg cron_doctor "$(native_cmd cron-doctor cron doctor)" \
  '{kanban:{stats:$stats,notify_subscribe:$subscriptions},monitoring:$monitoring,insights:$insights,doctor:$doctor,cron:{list:$cron,doctor:$cron_doctor},dossier_reflex:{status:"unknown",reason:"No native dossier/reflex reader is registered"}}')

prior='null'
if [ -n "$previous" ]; then
  [ -r "$previous" ] || { printf 'fm-vigie: event baseline is not readable: %s\n' "$previous" >&2; exit 2; }
  prior=$(jq -c . "$previous") || { printf 'fm-vigie: event baseline is not valid JSON\n' >&2; exit 2; }
fi

result=$(jq -c --argjson max "$MAX" --argjson age_days "$AGE_DAYS" --argjson daily "$daily" --argjson prior "$prior" --argjson native "$native" '
  def arr($x): if ($x|type)=="array" then $x else [] end;
  def text($x): if ($x|type)=="string" then $x else "" end;
  def rec($key; $action; $title; $reason; $evidence; $unknowns; $age):
    {key:$key, action:$action, title:$title, reason:$reason,
     evidence:$evidence, unknowns:$unknowns, age_days:$age};
  (.backlog // {}) as $backlog |
  (arr($backlog.records)) as $records |
  (arr(.tasks)) as $tasks |
  (arr(.secondmate_current.records)) as $secondmates |
  ($native) as $native |
  # Native command output is retained as evidence.  Only deterministic,
  # machine-readable counts are projected into recommendations; prose remains
  # an unknown source observation rather than a guessed task state.
  (try ($native.kanban.stats | sub("^[^{]*"; "") | fromjson) catch null) as $kanban_stats |
  ([($native.doctor | split("\\n")[]? | select(test("⚠|not logged|No API key")))]) as $credential_lines |
  ([($native.cron.doctor | split("\\n")[]? | select(test("issue|failed|not found"; "i")))]) as $cron_lines |
  # Ready PRs are projected from the native backlog records.  The optional
  # top-level fields are accepted only when a producer explicitly supplies
  # them; they are never synthesized by Vigie.
  (arr(.ready_prs) + [$records[]? | select(.pr_url != null and (.state == "in_flight" or .state == "queued" or .state == "In flight" or .state == "Queued")) |
    {id:.id, url:.pr_url, title:.title, state:.state, gate:(.gate // "PR review"), source:"backlog.records"}]) as $prs |
  (if has("client_gates") then arr(.client_gates) else [] end) as $gates |
  (if has("credential_evidence") then arr(.credential_evidence) else [] end) as $credentials |
  (if has("pending_services") then arr(.pending_services) else [] end) as $pending |
  ([
    ($prs[]? | ("pr:" + text(.id)) as $k |
      rec($k; "review-pr:" + text(.id); ("PR ready: " + text(.title // .id));
        "Review the recorded PR/client gate";
        [{source:(.source // "snapshot.ready_prs"), id:.id, url:(.url // null), title:(.title // null), state:(.state // null), gate:(.gate // null)}];
        (if (.url // null) == null then ["PR URL is unavailable"] else [] end); (.age_days // null))),
    ($gates[]? | ("gate:" + text(.id // .key)) as $k |
      rec($k; "stage-gate:" + text(.id // .key); text(.title // .name // .id);
        text(.reason // "Client stage gate is pending");
        [{source:"snapshot.client_gates", id:(.id // .key // null), title:(.title // .name // null), status:(.status // null), due:(.due // .due_at // null)}];
        (if (.id // .key // null) == null then ["Client gate identifier is unavailable"] else [] end); (.age_days // null))),
    ($tasks[]? | . as $task | (arr(.hints.open_decisions)[]? |
      ("decision:" + text(.key)) as $k |
      rec($k; "decide:" + text(.key); text(.summary // .key); "Keyed decision remains open";
        [{source:"tasks.hints.open_decisions", task_id:$task.id, key:.key, summary:(.summary // null), owner:(.owner // null), deadline:(.deadline // null)}];
        ["Decision owner and deadline are not inferred"]; null))),
    ($secondmates[]? | (arr(.decisions_open)[]? |
      ("decision:" + text(.key)) as $k |
      rec($k; "decide:" + text(.key); text(.summary // .key); "Secondmate keyed decision remains open";
        [{source:"secondmate_current.decisions_open", key:.key, summary:(.summary // null), owner:(.owner // null)}];
        ["Return-channel freshness is source-owned"]; null))),
    ($credentials[]? | select((.status // "") != "ok") |
      ("credential:" + text(.id // .source)) as $k |
      rec($k; "inspect-credential:" + text(.id // .source); text(.title // .source);
        text(.reason // "Credential evidence needs review"); [{source:(.source // "snapshot.credential_evidence"), id:(.id // null), status:(.status // null), observed_at:(.observed_at // null)}];
 ["Vigie never probes or changes credentials"]; (.age_days // null))),
    ($pending[]? | ("pending:" + text(.id // .key // .name)) as $k |
      rec($k; "resolve-pending:" + text(.id // .key // .name); text(.title // .name // .id);
        text(.reason // "Pending service or update decision");
        [{source:"snapshot.pending_services", id:(.id // .key // null), title:(.title // .name // null), status:(.status // null), age_days:(.age_days // null)}];
        ["Vigie never changes services or updates"]; (.age_days // null))),

    ($records[]? |
      select((.captain_actionable // false) == true) |
      ("answer:" + text(.id)) as $a |
      rec($a; $a; ("Captain hold " + text(.id));
        (if ((.hold_age_days // null)|type) == "number" and .hold_age_days >= 14
         then "Captain hold is aged and still actionable"
         else "Captain decision is waiting"
         end);
        ["fm-fleet-snapshot.backlog.records", (if (.hold_age_days // null) != null then "hold_age_days" else "captain_actionable" end)];
        ["The captain must answer or release the held work"];
        (.hold_age_days // null))
    ),
    ($records[]? |
      select((arr(.blocked_by_ids)|length) > 0 and ((.state // "") != "Done")) |
      ("unblock:" + text(.id)) as $a |
      rec($a; $a; ("Unblock " + text(.id));
        ("Work is blocked by " + ((arr(.blocked_by_ids)|join(", "))));
        ["fm-fleet-snapshot.backlog.records", "blocked_by_ids"];
        ["A blocker is unresolved until its authoritative task is Done"];
        null)
    ),
    ($tasks[]? |
      select((.endpoint.agent_alive // "unknown") == false) |
      ("inspect:" + text(.id)) as $a |
      rec($a; $a; ("Inspect " + text(.id)); "Recorded worker endpoint is not alive";
        ["fm-fleet-snapshot.tasks", "endpoint.agent_alive"];
        ["Current state needs targeted reconciliation before action"];
        null)
    )
    ,(if ($kanban_stats.by_status.ready // null) != null and ($kanban_stats.by_status.ready|tonumber) > 0 then
       rec("kanban:ready"; "inspect:kanban-ready"; "Ready Kanban work";
         "Native Kanban stats report ready work";
         [{source:"hermes kanban stats --json", ready:($kanban_stats.by_status.ready|tonumber), by_status:$kanban_stats.by_status}];
         []; null)
      else empty end)
    ,(if ($credential_lines|length)>0 then rec("credential:native-doctor"; "inspect-credential:native"; "Source credential evidence";
       "Native doctor reported credential/configuration attention";
       [{source:"hermes doctor", observations:$credential_lines}]; ["Vigie never probes or changes credentials"]; null) else empty end)
    ,(if ($cron_lines|length)>0 then
       rec("pending:native-cron"; "resolve-pending:native-cron"; "Cron/service pending attention";
         "Native cron doctor reported a scheduled-job issue";
         [{source:"hermes cron doctor", observations:$cron_lines}]; ["Vigie never changes services or updates"]; null)
      else empty end)
  ] | sort_by([.action, .key]) | unique_by(.key) |
    map(select((.age_days // 0) >= 0))) as $all_recommendations |
  ($all_recommendations[0:$max]) as $recommendations |
  ([ $tasks[]?.hints.open_decisions[]?, $secondmates[]?.decisions_open[]? ]) as $decisions |
  (if ($prior|type) == "object" then
     ([($prior.recommendations // [])[]?.key] | unique) as $old |
     {new: [$all_recommendations[] as $r | select(($old|index($r.key)) == null) | $r.key],
      resolved: [$old[] as $k | select(([$all_recommendations[]?.key] | index($k)) == null) | $k],
      resurfaced: (if $daily then [$all_recommendations[] as $r | select(($old|index($r.key)) != null and (($r.age_days // 0) >= $age_days)) | $r.key] else [] end)}
   else {new:[], resolved:[], resurfaced:[]} end) as $changes |
  {schema:"fm-vigie.v1", generated:(.generated // "unknown"), cadence:(if $daily then "daily" elif ($prior|type)=="object" then "event" else "daily" end),
   bounded:true, max:$max, recommendations:$recommendations, changes:$changes,
   inventory:{ready_prs:{count:($prs|length),status:(if ($prs|length)>0 then "observed" else "unknown" end)}, client_gates:{count:($gates|length),status:(if has("client_gates") then "observed" else "unknown" end)}, keyed_decisions:{count:($decisions|length),status:(if ($decisions|length)>0 then "observed" else "unknown" end)}, credential_evidence:{count:(($credentials|length)+($credential_lines|length)),status:(if has("credential_evidence") or ($credential_lines|length)>0 then "observed" else "unknown" end)}, pending_service_updates:{count:(($pending|length)+ (if ($cron_lines|length)>0 then 1 else 0 end)),status:(if has("pending_services") or ($cron_lines|length)>0 then "observed" else "unknown" end)}},
   delivery:{pilot_channel:"approved pilot only", desktop:"future; not activated", scheduled:false},
   sources:["fm-fleet-snapshot", "hermes kanban show/stats/notify-subscribe", "hermes monitoring/insights/doctor/cron", "dossier/reflex"],
   native:$native,
   unknowns:[(if ($decisions|length)==0 then "Keyed decision evidence is unavailable in the snapshot" else empty end), (if ($gates|length)==0 then "Client stage-gate evidence is unavailable in native sources" else empty end), (if (($credentials|length)+($credential_lines|length))==0 then "Source-specific credential evidence is unavailable in native sources" else empty end), (if (($pending|length)+($cron_lines|length))==0 then "Pending service/update decisions are unavailable in native sources" else empty end), "Display does not close work"]}
' <<<"$current") || { printf 'fm-vigie: could not build digest\n' >&2; exit 1; }

case "$format" in
  json) printf '%s\n' "$result" ;;
  toon)
    jq -r '"schema:" + .schema, "generated:" + .generated, "cadence:" + .cadence,
      "bounded:" + (.bounded|tostring) + " max:" + (.max|tostring),
      (if (.recommendations|length)==0 then "recommendations[0]:" else
        "recommendations[" + (.recommendations|length|tostring) + "]:",
        (.recommendations[] | .action + " | " + .reason) end),
      "delivery:pilot=" + .delivery.pilot_channel + " desktop=" + .delivery.desktop,
      "unknowns[" + (.unknowns|length|tostring) + "]:", (.unknowns[] | "- " + .)' <<<"$result" ;;
  fr)
    jq -r '
      "Vigie quotidienne (" + (.recommendations|length|tostring) + "/" + (.max|tostring) + ")",
      (if (.recommendations|length)==0 then "Aucune recommandation actionnable." else
        .recommendations[] | "- " +
          (if (.action|startswith("answer:")) then "Répondre à " + (.action|sub("^answer:";""))
           elif (.action|startswith("unblock:")) then "Débloquer " + (.action|sub("^unblock:";""))
           elif (.action|startswith("review-pr:")) then "Relire la PR " + (.action|sub("^review-pr:";""))
           elif (.action|startswith("stage-gate:")) then "Traiter l\u2019étape client " + (.action|sub("^stage-gate:";""))
           elif (.action|startswith("decide:")) then "Décider " + (.action|sub("^decide:";""))
           elif (.action|startswith("inspect-credential:")) then "Vérifier les éléments d\u2019accès " + (.action|sub("^inspect-credential:";""))
           elif (.action|startswith("resolve-pending:")) then "Résoudre l\u2019attente " + (.action|sub("^resolve-pending:";""))
           elif (.action|startswith("inspect:")) then "Inspecter " + (.action|sub("^inspect:";""))
           else "Examiner " + .action end) + " : " + .reason end),
      "Livraison : pilote approuvé uniquement ; bureau futur non activé."
    ' <<<"$result" ;;
esac
