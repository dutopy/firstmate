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
MAX="${FM_VIGIE_MAX:-10}"
case "$MAX" in ''|*[!0-9]*|0) printf 'fm-vigie: FM_VIGIE_MAX must be a positive integer\n' >&2; exit 2 ;; esac

usage() {
  printf '%s\n' \
    'usage: fm-vigie.sh [--json|--fr] [--event <previous.json>] [--daily]' \
    '' \
    'Read-only bounded recommendation digest over fm-fleet-snapshot.sh.' \
    'Default output is compact AXI/TOON; --json is machine-readable; --fr is' \
    'a concise French notification surface. --event compares event identities' \
    'with a prior JSON digest. No mode mutates work or schedules delivery.'
}

format=toon
previous=
while [ $# -gt 0 ]; do
  case "$1" in
    --json) format=json ;;
    --fr) format=fr ;;
    --daily) : ;;
    --event) shift; previous=${1-} ;;
    --event=*) previous=${1#--event=} ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-vigie: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { printf 'fm-vigie: jq is required\n' >&2; exit 1; }
[ -x "$SNAPSHOT" ] || { printf 'fm-vigie: snapshot command is unavailable: %s\n' "$SNAPSHOT" >&2; exit 1; }
current=$($SNAPSHOT --json) || { printf 'fm-vigie: fleet snapshot failed\n' >&2; exit 1; }
printf '%s\n' "$current" | jq -e 'type == "object" and (.schema|type)=="string"' >/dev/null \
  || { printf 'fm-vigie: fleet snapshot was not structured JSON\n' >&2; exit 1; }

prior='null'
if [ -n "$previous" ]; then
  [ -r "$previous" ] || { printf 'fm-vigie: event baseline is not readable: %s\n' "$previous" >&2; exit 2; }
  prior=$(jq -c . "$previous") || { printf 'fm-vigie: event baseline is not valid JSON\n' >&2; exit 2; }
fi

result=$(jq -c --argjson max "$MAX" --argjson prior "$prior" '
  def arr($x): if ($x|type)=="array" then $x else [] end;
  def text($x): if ($x|type)=="string" then $x else "" end;
  def rec($action; $title; $reason; $evidence; $unknowns; $age):
    {key:$action, action:$action, title:$title, reason:$reason,
     evidence:$evidence, unknowns:$unknowns, age_days:$age};
  (.backlog // {}) as $backlog |
  (arr($backlog.records)) as $records |
  (arr(.tasks)) as $tasks |
  ([
    ($records[]? |
      select((.captain_actionable // false) == true) |
      ("answer:" + text(.id)) as $a |
      rec($a; ("Captain hold " + text(.id));
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
      rec($a; ("Unblock " + text(.id));
        ("Work is blocked by " + ((arr(.blocked_by_ids)|join(", "))));
        ["fm-fleet-snapshot.backlog.records", "blocked_by_ids"];
        ["A blocker is unresolved until its authoritative task is Done"];
        null)
    ),
    ($tasks[]? |
      select((.endpoint.agent_alive // "unknown") == false) |
      ("inspect:" + text(.id)) as $a |
      rec($a; ("Inspect " + text(.id)); "Recorded worker endpoint is not alive";
        ["fm-fleet-snapshot.tasks", "endpoint.agent_alive"];
        ["Current state needs targeted reconciliation before action"];
        null)
    )
  ] | sort_by([.action, .key]) | unique_by(.key) | .[0:$max]) as $recommendations |
  (if ($prior|type) == "object" then
     ([($prior.recommendations // [])[]?.key] | unique) as $old |
     {new: [$recommendations[] as $r | select(($old|index($r.key)) == null) | $r.key],
      resolved: [$old[] as $k | select(([$recommendations[]?.key] | index($k)) == null) | $k]}
   else {new:[], resolved:[]} end) as $changes |
  {schema:"fm-vigie.v1", generated:(.generated // "unknown"), cadence:"daily",
   bounded:true, max:$max, recommendations:$recommendations, changes:$changes,
   delivery:{pilot_channel:"approved pilot only", desktop:"future; not activated", scheduled:false},
   sources:["fm-fleet-snapshot", "kanban show/stats/notify-subscribe", "monitoring/insights/doctor/cron", "dossier/reflex"],
   unknowns:["Source-specific credentials and service/update decisions are not executed or inferred", "Display does not close work"]}
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
        .recommendations[] | "- " + (if (.action|startswith("answer:")) then "Répondre à " + (.action|sub("^answer:";"")) elif (.action|startswith("unblock:")) then "Débloquer " + (.action|sub("^unblock:";"")) else "Inspecter " + (.action|sub("^inspect:";"")) end) + " : " + .reason end),
      "Livraison : pilote approuvé uniquement ; bureau futur non activé."
    ' <<<"$result" ;;
esac
