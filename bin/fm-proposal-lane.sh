#!/usr/bin/env bash
# fm-proposal-lane.sh - turn friction the fleet already recorded into bounded,
# evidence-anchored improvement proposals the operator can accept or decline.
#
# Usage:
#   fm-proposal-lane.sh scan [--force]       run the observation pass now
#   fm-proposal-lane.sh list [--all] [--json]
#   fm-proposal-lane.sh show <id> [--json]   one proposal with its evidence
#   fm-proposal-lane.sh digest [--json]      the bounded card of 3-5 proposals
#   fm-proposal-lane.sh accept <id> [--task <backlog-id>] [--repo <name>] [--title <title>]
#   fm-proposal-lane.sh decline <id> [--reason <text>]
#   fm-proposal-lane.sh supersede <id> [--reason <text>]
#   fm-proposal-lane.sh reopen <id>          undo a decline, a supersession, or an accept
#   fm-proposal-lane.sh pause                silence the lane
#   fm-proposal-lane.sh resume               restore the lane
#   fm-proposal-lane.sh status               report lane state from records only
#   fm-proposal-lane.sh check                watcher check body; one line when a card is due
#   fm-proposal-lane.sh arm                  wire the check into the watcher
#   fm-proposal-lane.sh disarm               retire the installed check
#   fm-proposal-lane.sh --help
#
# WHY. The operator kept supplying the improvement ideas himself - a card-based
# correction for an uncertain transcription, a faster confirmation path, an
# automatic stop for a review that repeats - and every one of them was friction
# the fleet had already recorded. This lane closes that gap: it reads the
# records the fleet already writes, notices the friction that keeps recurring,
# and brings a bounded set of concrete proposals instead of waiting to be told.
#
# WHAT IT OBSERVES. Only records that already exist under this home: worker
# status events (state/<id>.status), the backlog, captured operator notes
# (state/inbox/*.note), the durable operator preference record, and the closing
# notes of finished tasks (data/*/report.md). Two detectors run over them:
#   - the declared friction catalog bin/fm-proposal-rules.tsv, one rule per
#     known friction family, each firing only when its own thresholds of
#     matching lines and distinct sources are met;
#   - an emergent pass over keyed blocker families, which normalizes decision
#     and blocker keys into shapes (nm-<id>-review<n>) and proposes a family
#     that recurred across sources without any rule having named it.
# Every proposal carries at least one captured evidence line naming the exact
# record and line number it came from, so a proposal without evidence cannot
# exist. An emergent family whose every evidence line is already claimed by a
# fired rule is skipped, so one friction is proposed once.
#
# WHAT IT NEVER DOES. It never changes fleet behaviour, never writes a project,
# never merges, never dispatches work, and never files work that was not
# accepted. `accept` files the one accepted item through bin/fm-tasks-axi.sh,
# the ordinary backlog path, and nothing else. Its only captain-facing surface
# is the one bounded card `digest` renders at its cadence; it posts nothing
# anywhere by itself. A declined proposal is never proposed again: the ledger
# keeps the decision and the merge program refuses to revive a decided record.
#
# The durable ledger is data/proposals.jsonl, one JSON record per proposal, and
# bin/fm-proposal-lane.jq owns the merge contract a scan applies to it.
# docs/proposal-lane.md owns the behaviour contract, its never-do list, and the
# extension point; docs/configuration.md owns the config schema and the home
# layout; .agents/skills/proposal-lane/SKILL.md owns the wake procedure.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"

LEDGER="$DATA/proposals.jsonl"
RULES="${FM_PROPOSAL_RULES:-$SCRIPT_DIR/fm-proposal-rules.tsv}"
MERGE_JQ="$SCRIPT_DIR/fm-proposal-lane.jq"
CONFIG_FILE="$CONFIG_DIR/proposals.json"
CHECK_ID=proposals
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
TASKS_BIN="$SCRIPT_DIR/fm-tasks-axi.sh"
LAST_SCAN_RECORD="$STATE/.proposal-lane-last-scan"
LAST_CARD_RECORD="$STATE/.proposal-lane-last-card"
LANE_LOCK="$STATE/.proposal-lane.lock"

# Defaults. docs/configuration.md owns the schema; every value is overridable
# from config/proposals.json and, for tests and one-off runs, from the
# environment variable named beside it.
DEFAULT_INTERVAL=604800      # FM_PROPOSAL_INTERVAL      seconds between cards
DEFAULT_SCAN_INTERVAL=86400  # FM_PROPOSAL_SCAN_INTERVAL seconds between passes
DEFAULT_CARD_MAX=5           # FM_PROPOSAL_MAX           proposals per card
DEFAULT_CARD_MIN=3           # FM_PROPOSAL_MIN           proposals a card aims for
DEFAULT_KEY_MIN=3            # FM_PROPOSAL_KEY_MIN       events for a keyed family
DEFAULT_KEY_MIN_TASKS=2      # FM_PROPOSAL_KEY_MIN_TASKS distinct sources for it
DEFAULT_STALE_DAYS=30        # FM_PROPOSAL_STALE_DAYS    unobserved days before supersession

EVIDENCE_MAX=8
EVIDENCE_WIDTH=280
TEXT_WIDTH=200
# A keyed decision or blocker whose whole key is generic names no subject, so a
# family built from it would say nothing.
GENERIC_KEY_LIST=' default '

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"

die() {
  printf 'fm-proposal-lane: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# --- records, clock, and text helpers --------------------------------------

now_epoch() { date +%s; }
today_utc() { date -u +%Y-%m-%d; }

read_epoch() {  # <file>  -> prints the recorded epoch, nothing when absent
  [ -f "$1" ] || return 0
  local value
  value=$(head -n 1 "$1" 2>/dev/null | tr -cd '0-9')
  [ -n "$value" ] || return 0
  printf '%s' "$value"
}

write_epoch() {  # <file> <epoch>
  local tmp
  tmp=$(mktemp "$STATE/.proposal-lane-record.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$1"
}

human_age() {  # <epoch>  -> "3m ago"
  local then=$1 delta
  delta=$(( $(now_epoch) - then ))
  [ "$delta" -ge 0 ] || delta=0
  if [ "$delta" -lt 90 ]; then
    printf '%ds ago' "$delta"
  elif [ "$delta" -lt 5400 ]; then
    printf '%dm ago' $((delta / 60))
  elif [ "$delta" -lt 172800 ]; then
    printf '%dh ago' $((delta / 3600))
  else
    printf '%dd ago' $((delta / 86400))
  fi
}

truncate_text() {  # <text> <width>
  local text=$1 width=$2
  if [ "${#text}" -le "$width" ]; then
    printf '%s' "$text"
  else
    printf '%s...' "${text:0:$width}"
  fi
}

# A path is only ever built by appending this script's own fixed record names,
# so no producer may introduce a newline into one.
single_line_text() {  # <text>
  printf '%s' "$1" | tr '\n\r' '  '
}

# --- configuration ----------------------------------------------------------

config_value() {  # <key>  -> the JSON scalar, nothing when absent
  [ -f "$CONFIG_FILE" ] || return 0
  jq -r --arg k "$1" '
    if (type == "object") and (has($k)) then (.[$k] | tostring) else empty end
  ' "$CONFIG_FILE" 2>/dev/null || return 0
}

config_check() {
  [ -e "$CONFIG_FILE" ] || return 0
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
    || die "$CONFIG_FILE must be an ordinary file"
  if ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    die "$CONFIG_FILE is not a JSON object; docs/configuration.md owns the schema"
  fi
}

PROPOSAL_CFG_VALUE=
config_resolve() {  # <key> <env-var> <default> <min> <max> <label>
  local key=$1 env=$2 def=$3 min=$4 max=$5 label=$6 raw value
  raw=${!env:-}
  if [ -n "$raw" ]; then
    value=$raw
  else
    value=$(config_value "$key")
  fi
  [ -n "$value" ] || value=$def
  case "$value" in
    ''|*[!0-9]*) die "$label must be a whole number (got '$value')" ;;
  esac
  if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    die "$label must be between $min and $max (got '$value')"
  fi
  PROPOSAL_CFG_VALUE=$value
}

# config_flag <key> <env-var>: succeeds when the flag is on, fails when off.
config_flag() {
  local key=$1 env=$2 raw value
  raw=${!env:-}
  if [ -n "$raw" ]; then
    value=$raw
  else
    value=$(config_value "$key")
  fi
  case "$value" in
    ''|false|0|no|off) return 1 ;;
    true|1|yes|on) return 0 ;;
    *) die "$key in $CONFIG_FILE must be true or false (got '$value')" ;;
  esac
}

lane_paused() {
  config_check
  config_flag paused FM_PROPOSAL_PAUSED
}

config_write_flag() {  # <paused-boolean>
  local paused=$1 tmp
  config_check
  mkdir -p "$CONFIG_DIR" || die "cannot create $CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/.proposals.XXXXXX") || die "cannot stage $CONFIG_FILE"
  if [ -f "$CONFIG_FILE" ]; then
    if ! jq --argjson p "$paused" '. + {paused: $p}' "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      die "$CONFIG_FILE is unreadable; fix or remove it before pausing the lane"
    fi
  else
    printf '{\n  "paused": %s\n}\n' "$paused" > "$tmp"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$CONFIG_FILE" || die "cannot replace $CONFIG_FILE"
}

# --- durable ledger ---------------------------------------------------------

LANE_LOCK_SOURCED=0
lane_lock() {
  if [ "$LANE_LOCK_SOURCED" = 0 ]; then
    # Sourced lazily so read-only subcommands never drag the wake-queue
    # machinery, which creates the state directory at source time.
    # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    LANE_LOCK_SOURCED=1
  fi
  mkdir -p "$STATE" || die "cannot create $STATE"
  fm_lock_acquire_wait "$LANE_LOCK" || die "cannot lock the proposal ledger"
}

lane_unlock() {
  fm_lock_release "$LANE_LOCK"
}

ledger_check() {
  [ -e "$LEDGER" ] || return 0
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] \
    || die "$LEDGER must be an ordinary file, not a symlink or directory"
}

ledger_records() {  # [<state>...]  -> the records, one compact JSON object per line
  ledger_check
  [ -f "$LEDGER" ] || return 0
  if [ "$#" -eq 0 ]; then
    jq -c '.' "$LEDGER" 2>/dev/null || die "$LEDGER is not valid JSON lines"
    return 0
  fi
  local states_json
  states_json=$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -c --argjson states "$states_json" \
    'select(.state as $s | ($states | index($s)) != null)' "$LEDGER" 2>/dev/null \
    || die "$LEDGER is not valid JSON lines"
}

ledger_record() {  # <id>
  ledger_records | jq -c --arg id "$1" 'select(.id == $id)' | head -n 1
}

record_field() {  # <json> <field>
  printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // ""'
}

record_count() {  # <state-filter-args...>
  local n
  n=$(ledger_records "$@" | grep -c . || true)
  printf '%s' "${n:-0}"
}

# Replace one record's state and decision fields. The caller holds the lock.
ledger_update() {  # <id> <jq-object-expression>
  local id=$1 patch=$2 tmp
  ledger_check
  [ -f "$LEDGER" ] || die "no proposal ledger exists yet; run scan first"
  tmp=$(mktemp "$DATA/.proposals.XXXXXX") || die "cannot stage the ledger"
  if ! jq -c --arg id "$id" --argjson patch "$patch" '
        if .id == $id then . + $patch else . end
      ' "$LEDGER" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    die "$LEDGER is not valid JSON lines"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$LEDGER" || die "cannot replace $LEDGER"
}

# --- observation pass ------------------------------------------------------

lane_files() {  # <dir> <name-glob> [<depth>]
  local dir=$1 name=$2 depth=${3:-1}
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth "$depth" -maxdepth "$depth" -name "$name" -type f -print 2>/dev/null \
    | LC_ALL=C sort
}

lane_collect() {  # <out> <flat-bucket-name> <awk-program> <dir> <glob> <depth>...
  local out=$1 bucket=$2 program=$3
  shift 3
  local -a files=()
  local f
  [ "$#" -ge 3 ] && [ $(( $# % 3 )) -eq 0 ] || die "lane_collect needs dir/glob/depth triples"
  while [ "$#" -ge 3 ]; do
    while IFS= read -r f; do
      files+=("$f")
    done < <(lane_files "$1" "$2" "$3")
    shift 3
  done
  : > "$out"
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v OFS='\t' -v b="$bucket" "$program" "${files[@]}" >> "$out"
}

# bucket, path, line number, text - the shape every collector emits.
# The single-quoted programs are awk source, so their $0, FNR, and FILENAME must
# reach awk unexpanded.
# shellcheck disable=SC2016  # awk source, deliberately not expanded by the shell.
COLLECT_BASENAME='{ b=FILENAME; sub(/^.*\//,"",b); sub(/\.[a-z]+$/,"",b); line=$0; sub(/\r$/,"",line); print b, FILENAME, FNR, line }'
# shellcheck disable=SC2016  # awk source, deliberately not expanded by the shell.
COLLECT_REPORT='{ b=FILENAME; sub(/\/report\.md$/,"",b); sub(/^.*\//,"",b); line=$0; sub(/\r$/,"",line); print b, FILENAME, FNR, line }'
# shellcheck disable=SC2016  # awk source, deliberately not expanded by the shell.
COLLECT_FLAT='{ line=$0; sub(/\r$/,"",line); print b, FILENAME, FNR, line }'

# Keyed blocked/paused/needs-decision events, normalized into family shapes.
# Only these three verbs mean friction: a resolved or done line is the end of
# one, and a correlation key repeated across one lifecycle is not a family.
# shellcheck disable=SC2016  # awk source, deliberately not expanded by the shell.
COLLECT_KEYS='
  !/^(blocked|paused|needs-decision)(:|[ \t])/ { next }
  {
    line = $0
    sub(/\r$/, "", line)
    while (match(line, /\[key=[^]]+\]/)) {
      k = substr(line, RSTART + 5, RLENGTH - 6)
      gsub(/[0-9A-Z]{16,}/, "<id>", k)
      gsub(/[0-9a-f]{8,}/, "<hash>", k)
      gsub(/[0-9]+/, "<n>", k)
      print tolower(k), FILENAME, FNR, line
      line = substr(line, RSTART + RLENGTH)
    }
  }
'

collect_all() {  # <workdir>
  local dir=$1
  lane_collect "$dir/status.lines" - "$COLLECT_BASENAME" "$STATE" '*.status' 1
  lane_collect "$dir/notes.lines" - "$COLLECT_BASENAME" \
    "$STATE/inbox" '*.note' 1 "$STATE/inbox/handled" '*.note' 1
  lane_collect "$dir/backlog.lines" backlog "$COLLECT_FLAT" "$DATA" 'backlog.md' 1
  lane_collect "$dir/captain.lines" captain "$COLLECT_FLAT" "$DATA" 'captain.md' 1
  lane_collect "$dir/reports.lines" - "$COLLECT_REPORT" "$DATA" 'report.md' 2
  lane_collect "$dir/keys.lines" - "$COLLECT_KEYS" "$STATE" '*.status' 1
}

slugify() {  # <text> <max-length>
  local text=$1 max=$2
  printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
    | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//' \
    | cut -c "1-$max"
}

# Evidence for one rule or family, bounded and spread across sources: the first
# surviving line of each source, then further lines, newest file order kept.
evidence_select() {  # <matched-file> <evidence-file>
  local matched=$1 out=$2
  {
    LC_ALL=C sort -u -k1,1 "$matched"
    LC_ALL=C sort "$matched"
  } | awk '!seen[$0]++' | head -n "$EVIDENCE_MAX" > "$out"
}

# Render "path:line: text" lines from the collector's four-column shape.
evidence_render() {  # <evidence-file> <render-file>
  local in=$1 out=$2
  : > "$out"
  while IFS= read -r raw; do
    local bucket path lineno text
    bucket=${raw%%$'\t'*}
    raw=${raw#*$'\t'}
    path=${raw%%$'\t'*}
    raw=${raw#*$'\t'}
    lineno=${raw%%$'\t'*}
    text=${raw#*$'\t'}
    case "$path" in
      "$FM_HOME"/*) path=${path#"$FM_HOME"/} ;;
    esac
    printf '%s:%s: %s\n' "$path" "$lineno" "$(truncate_text "$text" "$EVIDENCE_WIDTH")" >> "$out"
  done < "$in"
}

emit_candidate() {  # <out> <id> <theme> <repo> <title> <change> <cost> <lines> <tasks> <matched-file>
  local out=$1 id=$2 theme=$3 repo=$4 title=$5 change=$6 cost=$7 lines=$8 tasks=$9
  local matched=${10}
  local evraw evjson
  evraw=$(mktemp) || return 1
  evidence_select "$matched" "$evraw"
  evidence_render "$evraw" "$evraw.rendered"
  evjson=$(jq -R -s 'split("\n") | map(select(length > 0))' "$evraw.rendered")
  rm -f -- "$evraw" "$evraw.rendered"
  jq -c -n \
    --arg id "$id" \
    --arg theme "$theme" \
    --arg repo "$repo" \
    --arg title "$title" \
    --arg change "$change" \
    --arg cost "$cost" \
    --argjson lines "$lines" \
    --argjson tasks "$tasks" \
    --argjson evidence "$evjson" \
    '{id: $id, theme: $theme, repo: $repo, title: $title, change: $change,
      cost: $cost, count_lines: $lines, count_tasks: $tasks, evidence: $evidence}' >> "$out"
}

rules_candidates() {  # <out> <workdir>
  local out=$1 dir=$2
  local rid source pattern min_lines min_tasks repo title change cost
  local matched nlines ntasks
  [ -f "$RULES" ] || die "the friction catalog $RULES is missing"
  : > "$dir/claimed"
  # A rule matches the record's own text, not the bucket/path/line-number
  # columns a collector prepends, so its ^ and $ anchors mean what they say.
  # Line numbers are identical in both views, so a hit maps straight back.
  for source in status notes backlog captain reports; do
    [ -f "$dir/$source.lines" ] || continue
    cut -f4- "$dir/$source.lines" > "$dir/text.$source"
  done
  while IFS=$'\t' read -r rid source pattern min_lines min_tasks repo title change cost; do
    [ -n "${rid:-}" ] || continue
    # A catalog typo must be loud: a rule that silently never matches is a
    # friction family nobody would notice was missing.
    case "${source:-}" in
      status|notes|backlog|captain|reports) : ;;
      *) die "rule $rid in $RULES names an unknown source '${source:-}'" ;;
    esac
    case "${min_lines:-x}${min_tasks:-x}" in
      *[!0-9]*) die "rule $rid in $RULES has a non-numeric threshold" ;;
    esac
    [ -f "$dir/text.$source" ] || continue
    matched="$dir/matched.$rid"
    grep -nE -- "$pattern" "$dir/text.$source" 2>/dev/null | cut -d: -f1 > "$dir/hits.$rid" || true
    awk -F'\t' 'NR == FNR { hit[$1] = 1; next } FNR in hit { print }' \
      "$dir/hits.$rid" "$dir/$source.lines" > "$matched"
    nlines=$(grep -c . "$matched" 2>/dev/null || true)
    [ -n "$nlines" ] || nlines=0
    ntasks=$(cut -f1 "$matched" 2>/dev/null | sort -u | grep -c . || true)
    [ -n "$ntasks" ] || ntasks=0
    if [ "$nlines" -ge "$min_lines" ] && [ "$ntasks" -ge "$min_tasks" ]; then
      emit_candidate "$out" "p-$rid" "rule:$rid" "$repo" "$title" "$change" "$cost" \
        "$nlines" "$ntasks" "$matched"
      cut -f2,3 "$matched" >> "$dir/claimed"
    fi
  done < <(grep -v '^#' "$RULES" | grep -v '^[[:space:]]*$')
}

clusters_candidates() {  # <out> <workdir>
  local out=$1 dir=$2 shape nlines ntasks
  local matched remaining key_min key_min_tasks
  [ -s "$dir/keys.lines" ] || return 0
  config_resolve key_min FM_PROPOSAL_KEY_MIN "$DEFAULT_KEY_MIN" 2 1000 "keyed family event floor"
  key_min=$PROPOSAL_CFG_VALUE
  config_resolve key_min_tasks FM_PROPOSAL_KEY_MIN_TASKS "$DEFAULT_KEY_MIN_TASKS" 1 1000 "keyed family source floor"
  key_min_tasks=$PROPOSAL_CFG_VALUE
  while IFS=$'\t' read -r shape nlines ntasks; do
    [ -n "$shape" ] || continue
    case "$GENERIC_KEY_LIST" in *" $shape "*) continue ;; esac
    matched="$dir/cluster.$(slugify "$shape" 40)"
    awk -F'\t' -v s="$shape" '$1 == s' "$dir/keys.lines" > "$matched"
    # Skip a family whose every line a fired rule already proposed on, so one
    # friction never produces two proposals.
    #
    # Command substitution strips the newline this comparison needs.
    remaining=$(
      comm -23 \
        <(cut -f2,3 "$matched" | sort -u) \
        <(sort -u "$dir/claimed" 2>/dev/null || true) | grep -c . || true
    )
    [ -n "$remaining" ] || remaining=0
    [ "$remaining" -gt 0 ] || continue
    emit_candidate "$out" "p-c-$(slugify "$shape" 40)" "cluster:$shape" "-" \
      "Recurring blocker family: $shape" \
      "Treat this recurring family as a structural stop or guard instead of a fresh hand decision each time it reappears." \
      "One bounded change; the exact design starts when this proposal is accepted." \
      "$nlines" "$ntasks" "$matched"
  done < <(
    awk -F'\t' -v OFS='\t' -v min="$key_min" -v mint="$key_min_tasks" '
      { b = $1 SUBSEP $2; if (!(b in seen)) { seen[b] = 1; tasks[$1]++ } lines[$1]++ }
      END { for (s in lines) if (lines[s] >= min && tasks[s] >= mint) print s, lines[s], tasks[s] }
    ' "$dir/keys.lines" | LC_ALL=C sort
  )
}

scan_run() {  # <workdir>
  local dir=$1
  local cands="$dir/candidates.jsonl"
  local now today stale_secs days tmp
  now=$(now_epoch)
  today=$(today_utc)
  config_resolve stale_days FM_PROPOSAL_STALE_DAYS "$DEFAULT_STALE_DAYS" 1 3650 "proposal stale horizon in days"
  days=$PROPOSAL_CFG_VALUE
  stale_secs=$((days * 86400))

  collect_all "$dir"
  : > "$cands"
  rules_candidates "$cands" "$dir"
  clusters_candidates "$cands" "$dir"
  mkdir -p "$DATA" || die "cannot create $DATA"
  ledger_check
  [ -f "$LEDGER" ] || : > "$LEDGER"
  tmp=$(mktemp "$DATA/.proposals.XXXXXX") || die "cannot stage the ledger"
  if ! jq -c -s -f "$MERGE_JQ" \
        --slurpfile cands "$cands" \
        --arg today "$today" \
        --argjson now "$now" \
        --argjson stale_secs "$stale_secs" \
        "$LEDGER" > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    die "the proposal ledger merge failed; $LEDGER and the catalog are unchanged"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$LEDGER" || die "cannot replace $LEDGER"
  write_epoch "$LAST_SCAN_RECORD" "$now" || true
}

# --- rendering --------------------------------------------------------------

proposals_due() {  # prints the proposed records, best first
  ledger_records proposed | jq -c -s '
    sort_by([-.count_tasks, -.count_lines, .theme]) | .[]'
}

card_lines() {  # <max> <min>
  local max=$1 min=$2 record index=0 shown=0 total title threshold ev_first ev_more
  total=$(proposals_due | grep -c . || true)
  [ -n "$total" ] || total=0
  threshold=$max
  [ "$total" -lt "$max" ] && threshold=$total
  printf 'proposal card %s - %s of %s open\n\n' "$(today_utc)" "$threshold" "$total"
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    index=$((index + 1))
    [ "$index" -le "$max" ] || break
    shown=$((shown + 1))
    title=$(truncate_text "$(single_line_text "$(record_field "$record" title)")" "$TEXT_WIDTH")
    ev_first=$(printf '%s' "$record" | jq -r '.evidence[0] // ""')
    ev_more=$(printf '%s' "$record" | jq -r '((.evidence | length) - 1) | if . < 0 then 0 else . end')
    printf '[%s] %s  (%s events across %s sources)\n' \
      "$index" "$(record_field "$record" id)" \
      "$(record_field "$record" count_lines)" "$(record_field "$record" count_tasks)"
    printf '    %s\n' "$title"
    printf '    evidence: %s\n' "$ev_first"
    if [ "$ev_more" -gt 0 ]; then
      printf '    (%s more evidence line(s) with: bin/fm-proposal-lane.sh show %s)\n' \
        "$ev_more" "$(record_field "$record" id)"
    fi
    printf '    change:  %s\n' "$(truncate_text "$(single_line_text "$(record_field "$record" change)")" "$EVIDENCE_WIDTH")"
    printf '    cost:    %s\n' "$(truncate_text "$(single_line_text "$(record_field "$record" cost)")" "$EVIDENCE_WIDTH")"
    printf '    answer:  bin/fm-proposal-lane.sh accept %s   (or decline)\n\n' "$(record_field "$record" id)"
  done < <(proposals_due)
  if [ "$shown" -eq 0 ]; then
    printf 'nothing new to propose right now\n'
  elif [ "$shown" -lt "$min" ]; then
    printf 'note: only %s open proposal(s); the lane adds one as soon as the records show new friction\n' "$shown"
  fi
}

# --- subcommands ------------------------------------------------------------

cmd_scan() {
  local force=0 arg dir
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *) die "scan does not accept '$arg'" ;;
    esac
  done
  if [ "$force" -eq 0 ] && lane_paused; then
    printf 'paused: the proposal lane is paused; nothing was observed\n'
    return 0
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-proposal-scan.XXXXXX") || die "cannot create a scan directory"
  scan_run "$dir"
  rm -rf -- "$dir"
  ledger_records proposed | grep -c . | tr -d '\n'
  printf ' proposal(s) open\n'
}

cmd_list() {
  local all=0 json=0 arg record state
  for arg in "$@"; do
    case "$arg" in
      --all) all=1 ;;
      --json) json=1 ;;
      *) die "list does not accept '$arg'" ;;
    esac
  done
  if [ "$json" -eq 1 ]; then
    if [ "$all" -eq 1 ]; then ledger_records; else ledger_records proposed; fi
    return 0
  fi
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    state=$(record_field "$record" state)
    [ "$all" -eq 1 ] || [ "$state" = proposed ] || continue
    printf '%-10s %-28s events=%-4s sources=%-3s %s\n' \
      "$state" "$(record_field "$record" id)" \
      "$(record_field "$record" count_lines)" "$(record_field "$record" count_tasks)" \
      "$(truncate_text "$(single_line_text "$(record_field "$record" title)")" "$TEXT_WIDTH")"
  done < <(if [ "$all" -eq 1 ]; then ledger_records; else proposals_due; fi)
}

cmd_show() {
  local id=${1:-} json=0 arg record
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      *) die "show does not accept '$arg'" ;;
    esac
  done
  [ -n "$id" ] || die "show needs a proposal id"
  record=$(ledger_record "$id")
  [ -n "$record" ] || die "no proposal $id"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$record"
    return 0
  fi
  printf '%s\n' "$record" | jq -r '
    "id:        " + .id,
    "state:     " + .state,
    "title:     " + .title,
    "change:    " + .change,
    "cost:      " + .cost,
    "project:   " + .repo,
    "first:     " + (.first_seen // "-"),
    "last:      " + (.last_seen // "-"),
    "scans:     " + ((.scans // 0) | tostring),
    "observed:  " + ((.count_lines // 0) | tostring) + " events across "
                   + ((.count_tasks // 0) | tostring) + " sources",
    (if .decided_at then "decided:   " + .decided_at + " by " + (.decided_by // "-") else empty end),
    (if .reason then "reason:    " + .reason else empty end),
    (if .work then "work:      " + .work else empty end),
    "evidence:",
    (.evidence[]? | "  " + .)'
}

cmd_digest() {
  local json=0 arg max min total
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      *) die "digest does not accept '$arg'" ;;
    esac
  done
  if lane_paused; then
    die "the proposal lane is paused; resume it with: bin/fm-proposal-lane.sh resume"
  fi
  cmd_scan >/dev/null
  config_resolve card_max FM_PROPOSAL_MAX "$DEFAULT_CARD_MAX" 1 20 "proposals per card"
  max=$PROPOSAL_CFG_VALUE
  config_resolve card_min FM_PROPOSAL_MIN "$DEFAULT_CARD_MIN" 1 20 "proposals a card aims for"
  min=$PROPOSAL_CFG_VALUE
  if [ "$json" -eq 1 ]; then
    proposals_due | head -n "$max"
    return 0
  fi
  total=$(proposals_due | grep -c . || true)
  [ -n "$total" ] || total=0
  if [ "$total" -eq 0 ]; then
    printf 'proposal card %s - nothing open\n' "$(today_utc)"
    return 0
  fi
  card_lines "$max" "$min"
}

PROPOSAL_RECORD=
require_proposal() {  # <id> <allowed-state...>  (sets PROPOSAL_RECORD; dies in the caller)
  local id=$1
  shift
  local state allowed
  PROPOSAL_RECORD=$(ledger_record "$id")
  [ -n "$PROPOSAL_RECORD" ] || die "no proposal $id"
  state=$(record_field "$PROPOSAL_RECORD" state)
  for allowed in "$@"; do
    [ "$state" = "$allowed" ] && return 0
  done
  case "$state" in
    declined) die "proposal $id was declined; reopen it first with: bin/fm-proposal-lane.sh reopen $id" ;;
    accepted) die "proposal $id was already accepted as backlog $(record_field "$PROPOSAL_RECORD" work)" ;;
    *) die "proposal $id is $state and cannot be decided again" ;;
  esac
}

cmd_accept() {
  local id=${1:-} task='' repo='' title=''
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      *) die "accept does not accept '$1'" ;;
    esac
  done
  [ -n "$id" ] || die "accept needs a proposal id"
  local record
  require_proposal "$id" proposed
  record=$PROPOSAL_RECORD
  [ -n "$title" ] || title=$(record_field "$record" title)
  [ -n "$repo" ] || repo=$(record_field "$record" repo)

  local today work='' body
  today=$(today_utc)
  if [ -z "$task" ]; then
    body=$(mktemp "${TMPDIR:-/tmp}/fm-proposal-body.XXXXXX") || die "cannot stage the backlog body"
    {
      printf 'Filed from proposal %s by bin/fm-proposal-lane.sh.\n\n' "$id"
      printf 'What it would change: %s\n\n' "$(record_field "$record" change)"
      printf 'Rough cost: %s\n\n' "$(record_field "$record" cost)"
      printf 'Evidence observed in the records:\n'
      printf '%s' "$record" | jq -r '.evidence[]? | "  " + .'
    } > "$body"
    local -a add_args=(add --mint "$title" --kind ship --body-file "$body" --json)
    [ -n "$repo" ] && [ "$repo" != - ] && add_args+=(--repo "$repo")
    local result
    result=""
    if ! result=$("$TASKS_BIN" "${add_args[@]}" 2>&1); then
      rm -f -- "$body"
      die "the backlog refused the new item: $result"
    fi
    rm -f -- "$body"
    work=$(printf '%s' "$result" | jq -r '.task.id // empty' 2>/dev/null)
    [ -n "$work" ] || die "the backlog did not return an item id for $id"
  else
    if ! "$TASKS_BIN" show "$task" >/dev/null 2>&1; then
      die "no backlog item $task to link"
    fi
    work=$task
  fi

  lane_lock
  ledger_update "$id" "$(jq -c -n --arg at "$today" --arg by "${FM_PROPOSAL_ACTOR:-firstmate}" --arg work "$work" \
    '{state: "accepted", decided_at: $at, decided_by: $by, work: $work}')"
  lane_unlock
  printf 'accepted: %s -> backlog %s\n' "$id" "$work"
  if [ -z "$task" ]; then
    printf 'the item is ordinary queued work now\n'
  fi
}

cmd_decline() {
  local id=${1:-} reason=''
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 ;;
      *) die "decline does not accept '$1'" ;;
    esac
  done
  [ -n "$id" ] || die "decline needs a proposal id"
  require_proposal "$id" proposed
  [ -n "$reason" ] || reason='declined by the operator'
  lane_lock
  ledger_update "$id" "$(jq -c -n --arg at "$(today_utc)" --arg by "${FM_PROPOSAL_ACTOR:-operator}" --arg reason "$(single_line_text "$reason")" \
    '{state: "declined", decided_at: $at, decided_by: $by, reason: $reason}')"
  lane_unlock
  printf 'declined: %s will not be proposed again unless it is reopened\n' "$id"
}

cmd_supersede() {
  local id=${1:-} reason=''
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2:-}; shift 2 ;;
      *) die "supersede does not accept '$1'" ;;
    esac
  done
  [ -n "$id" ] || die "supersede needs a proposal id"
  require_proposal "$id" proposed
  [ -n "$reason" ] || reason='superseded'
  lane_lock
  ledger_update "$id" "$(jq -c -n --arg at "$(today_utc)" --arg by "${FM_PROPOSAL_ACTOR:-firstmate}" --arg reason "$(single_line_text "$reason")" \
    '{state: "superseded", decided_at: $at, decided_by: $by, reason: $reason}')"
  lane_unlock
  printf 'superseded: %s\n' "$id"
}

cmd_reopen() {
  local id=${1:-}
  shift || true
  [ "$#" -eq 0 ] || die "reopen does not accept '$1'"
  [ -n "$id" ] || die "reopen needs a proposal id"
  require_proposal "$id" declined accepted superseded
  lane_lock
  ledger_update "$id" "$(jq -c -n '{state: "proposed", decided_at: null, decided_by: null, reason: null, work: null}')"
  lane_unlock
  printf 'reopened: %s is open for a decision again\n' "$id"
}

cmd_pause() {
  [ "$#" -eq 0 ] || die "pause does not accept '$1'"
  config_write_flag true
  printf 'paused: the proposal lane observes nothing and delivers nothing until it is resumed\n'
}

cmd_resume() {
  [ "$#" -eq 0 ] || die "resume does not accept '$1'"
  config_write_flag false
  printf 'resumed: the proposal lane is active again\n'
}

cmd_status() {
  local scan_epoch card_epoch interval scan_interval next
  config_check
  printf 'proposal lane: '
  if lane_paused; then printf 'paused\n'; else printf 'active\n'; fi
  printf 'catalog:       %s\n' "$RULES"
  printf 'ledger:        %s\n' "$LEDGER"
  if [ -f "$LEDGER" ]; then
    printf 'records:       %s total, %s proposed, %s accepted, %s declined, %s superseded\n' \
      "$(ledger_records | grep -c . || true)" \
      "$(record_count proposed)" "$(record_count accepted)" \
      "$(record_count declined)" "$(record_count superseded)"
  else
    printf 'records:       absent, no observation pass has run yet\n'
  fi
  config_resolve interval FM_PROPOSAL_INTERVAL "$DEFAULT_INTERVAL" 60 31536000 "proposal card interval"
  interval=$PROPOSAL_CFG_VALUE
  config_resolve scan_interval FM_PROPOSAL_SCAN_INTERVAL "$DEFAULT_SCAN_INTERVAL" 60 2592000 "proposal scan interval"
  scan_interval=$PROPOSAL_CFG_VALUE
  scan_epoch=$(read_epoch "$LAST_SCAN_RECORD")
  card_epoch=$(read_epoch "$LAST_CARD_RECORD")
  if [ -n "$scan_epoch" ]; then
    printf 'last pass:     %s (%s)\n' "$scan_epoch" "$(human_age "$scan_epoch")"
  else
    printf 'last pass:     never\n'
  fi
  if [ -n "$card_epoch" ]; then
    printf 'last card:     %s (%s)\n' "$card_epoch" "$(human_age "$card_epoch")"
    next=$((card_epoch + interval - $(now_epoch)))
    if [ "$next" -le 0 ]; then printf 'next card:     due now\n'; else printf 'next card:     in %ss\n' "$next"; fi
  else
    printf 'last card:     never\n'
    printf 'next card:     due now\n'
  fi
  printf 'cadence:       card %ss, pass %ss\n' "$interval" "$scan_interval"
  if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'watcher check: registered\n'
  else
    printf 'watcher check: not registered (arm it with: bin/fm-proposal-lane.sh arm)\n'
  fi
}

cmd_check() {
  [ "$#" -eq 0 ] || die "check does not accept '$1'"
  lane_paused && return 0
  local now scan_epoch card_epoch interval scan_interval due open
  now=$(now_epoch)
  config_resolve interval FM_PROPOSAL_INTERVAL "$DEFAULT_INTERVAL" 60 31536000 "proposal card interval"
  interval=$PROPOSAL_CFG_VALUE
  config_resolve scan_interval FM_PROPOSAL_SCAN_INTERVAL "$DEFAULT_SCAN_INTERVAL" 60 2592000 "proposal scan interval"
  scan_interval=$PROPOSAL_CFG_VALUE
  scan_epoch=$(read_epoch "$LAST_SCAN_RECORD")
  if [ -z "$scan_epoch" ] || [ $((now - scan_epoch)) -ge "$scan_interval" ]; then
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-proposal-scan.XXXXXX") || return 0
    scan_run "$dir" || { rm -rf -- "$dir"; return 0; }
    rm -rf -- "$dir"
  fi
  card_epoch=$(read_epoch "$LAST_CARD_RECORD")
  due=0
  if [ -z "$card_epoch" ] || [ $((now - card_epoch)) -ge "$interval" ]; then
    due=1
  fi
  [ "$due" -eq 1 ] || return 0
  open=$(proposals_due | grep -c . || true)
  [ -n "$open" ] || open=0
  [ "$open" -gt 0 ] || return 0
  write_epoch "$LAST_CARD_RECORD" "$now" || return 0
  printf 'proposal-lane: %s improvement proposals are waiting for a decision (bin/fm-proposal-lane.sh digest)\n' "$open"
}

cmd_arm() {
  [ "$#" -eq 0 ] || die "arm does not accept '$1'"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "$STATE is unavailable"
  case "$FM_HOME$STATE$DATA$CONFIG_DIR" in
    *"'"*) die "a home path containing a single quote cannot carry the generated check" ;;
  esac
  local tmp
  tmp=$(mktemp "$STATE/.proposals-check.XXXXXX") || die "cannot stage the check"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by fm-proposal-lane.sh arm; retire it with disarm.\n'
    printf "export FM_HOME='%s'\n" "$FM_HOME"
    printf "export FM_STATE_OVERRIDE='%s'\n" "$STATE"
    printf "export FM_DATA_OVERRIDE='%s'\n" "$DATA"
    printf "export FM_CONFIG_OVERRIDE='%s'\n" "$CONFIG_DIR"
    printf "exec '%s/fm-proposal-lane.sh' check\n" "$SCRIPT_DIR"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the check"; }
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the check"; }
  mv -f -- "$tmp" "$CHECK_SHIM" || die "cannot install $CHECK_SHIM"
  "$REGISTER_BIN" "$CHECK_ID" || die "the check could not be registered"
}

cmd_disarm() {
  [ "$#" -eq 0 ] || die "disarm does not accept '$1'"
  [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ] || {
    printf 'nothing to disarm: no proposal check is installed\n'
    return 0
  }
  "$UNREGISTER_BIN" "$CHECK_ID" || die "the check could not be retired"
}

# --- entry ------------------------------------------------------------------

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  digest) shift; cmd_digest "$@" ;;
  accept) shift; cmd_accept "$@" ;;
  decline) shift; cmd_decline "$@" ;;
  supersede) shift; cmd_supersede "$@" ;;
  reopen) shift; cmd_reopen "$@" ;;
  pause) shift; cmd_pause "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  status) shift; cmd_status "$@" ;;
  check) shift; cmd_check "$@" ;;
  arm) shift; cmd_arm "$@" ;;
  disarm) shift; cmd_disarm "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command '$1'; run --help" ;;
esac
