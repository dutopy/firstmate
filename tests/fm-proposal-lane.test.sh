#!/usr/bin/env bash
# Behavior tests for bin/fm-proposal-lane.sh, the friction-to-proposal lane.
#
# The lane's whole value is that a proposal cannot exist without evidence and
# cannot come back once it was declined, so those two are the cases that matter
# most:
#
#   * every proposal the observation pass creates carries a captured evidence
#     line naming the exact record and line number it came from, and a rule that
#     does not reach its own thresholds creates nothing at all;
#   * a declined proposal stays declined across a later scan that sees the same
#     evidence again, and never reappears in the card;
#   * the emergent pass proposes a keyed family no rule named, and skips one a
#     fired rule already claimed, so one friction yields one proposal;
#   * accept files exactly one real backlog item through bin/fm-tasks-axi.sh and
#     nothing else, and the accepted proposal leaves the card.
#
# Every case drives the real command line against a synthetic home under the
# test temp root, so no case reads or writes a real fleet's records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANE="$ROOT/bin/fm-proposal-lane.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-proposal-lane)

# lane <home> <args...>: run the lane against one fixture home.
lane() {
  local home=$1
  shift
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$LANE" "$@"
}

# make_home <name>: a scratch home with an empty backlog and the tracked
# tasks-axi configuration, so accept exercises the real backlog path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state/inbox/handled" "$home/data" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# ledger <home> <jq-filter>: read one field of the fixture's proposal ledger.
ledger() {
  local home=$1 filter=$2
  jq -r "$filter" "$home/data/proposals.jsonl"
}

# write_custody_evidence <home>: three blocked lines across two tasks that trip
# the nm-custody-recovery rule.
write_custody_evidence() {
  local home=$1
  {
    printf 'working: setup complete\n'
    printf 'blocked: guarded recovery refused with blocked_recover_preserved_head_missing; no guarded recovery was offered\n'
    printf 'blocked: blocked_recover_unverified_head; the preserved head could not be read from the gate\n'
  } > "$home/state/aaa.status"
  printf 'blocked: the preserved head is present but branch sync offers no recovery\n' > "$home/state/bbb.status"
}

test_observation_pass_names_the_record_and_line_of_every_proposal() {
  local home out
  home=$(make_home observe)
  write_custody_evidence "$home"
  out=$(lane "$home" scan) || fail "scan failed: $out"
  assert_contains "$out" "proposal(s) open" "scan reports what it found"

  assert_equals "1" "$(lane "$home" list --json | grep -c .)" "one rule proposal"
  assert_equals "rule:nm-custody-recovery" \
    "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.theme')" "the fired rule is named"
  assert_equals "3" \
    "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.count_lines')" "every matching line is counted"
  assert_equals "2" \
    "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.count_tasks')" "both source tasks are counted"
  # The evidence names the exact record and line, which is what makes the
  # proposal checkable rather than a claim.
  assert_contains "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.evidence[0]')" \
    "state/aaa.status:2:" "the first evidence line names its record and line"
  assert_contains "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.evidence[]' )" \
    "state/bbb.status:1:" "the second record is cited too"
  pass "proposal lane: every proposal names the record and line its evidence came from"
}

test_a_rule_below_its_threshold_proposes_nothing() {
  local home
  home=$(make_home below-threshold)
  printf 'blocked: blocked_recover_preserved_head_missing once\n' > "$home/state/only.status"
  lane "$home" scan >/dev/null
  assert_equals "0" "$(grep -c . "$home/data/proposals.jsonl" 2>/dev/null || true)" \
    "one line cannot satisfy a rule that needs three"
  pass "proposal lane: a rule below its own threshold proposes nothing"
}

test_emergent_family_is_proposed_and_a_claimed_one_is_skipped() {
  local home
  home=$(make_home emergent)
  # A keyed blocker family no rule names: four events across two tasks.
  {
    printf 'blocked: [key=quota-gateway-7] the route was refused\n'
    printf 'paused: [key=quota-gateway-8] waiting on the same route\n'
  } > "$home/state/em1.status"
  {
    printf 'blocked: [key=quota-gateway-9] the route was refused again\n'
    printf 'needs-decision: [key=quota-gateway-10] pick a route\n'
  } > "$home/state/em2.status"
  # A second family that a fired rule already claims.
  {
    printf 'blocked: [key=nm-01M1S2N84WEMB1K1N1GMPBJJ13-review3] repeated-family nonconvergence again\n'
    printf 'blocked: [key=nm-01M1S8EDZV16G1VKVN7K1911XH-review3] repeated-family nonconvergence again\n'
  } > "$home/state/em3.status"
  {
    printf 'needs-decision: [key=nm-01M1SEP8XKFS5M9REKJAJHY91B-review3] repeated-family nonconvergence again\n'
    printf 'needs-decision: [key=nm-01M1SHNH5S1QZDVAGRFBTFWWYB-review3] repeated-family nonconvergence again\n'
  } > "$home/state/em4.status"

  lane "$home" scan >/dev/null
  assert_equals "cluster:quota-gateway-<n>" \
    "$(ledger "$home" 'select(.theme|startswith("cluster:"))|.theme')" \
    "the undeclared family is proposed with its normalized shape"
  assert_equals "2" \
    "$(ledger "$home" 'select(.theme|startswith("cluster:"))|.count_tasks')" \
    "both tasks are counted for the emergent family"
  assert_equals "1" \
    "$(lane "$home" list --json | jq -c 'select(.theme|startswith("cluster:"))' | grep -c .)" \
    "a family the review rule already claimed is not proposed twice"
  pass "proposal lane: an undeclared family is proposed and a claimed one is skipped"
}

test_declined_proposal_is_never_re_proposed() {
  local home before after
  home=$(make_home decline)
  write_custody_evidence "$home"
  lane "$home" scan >/dev/null
  lane "$home" decline p-nm-custody-recovery --reason "already covered" >/dev/null
  before=$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.state')
  assert_equals "declined" "$before" "the decline is recorded"

  # The same evidence is still in the records, so only the kept decision can
  # keep the proposal out.
  lane "$home" scan >/dev/null
  after=$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.state')
  assert_equals "declined" "$after" "a later scan does not revive the declined proposal"
  assert_equals "1" "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.scans')" \
    "a decided proposal is not even refreshed"
  assert_equals "" "$(lane "$home" list --json | jq -c 'select(.id=="p-nm-custody-recovery")')" \
    "the declined proposal leaves the open list"

  # The card must not carry it either.
  assert_not_contains "$(lane "$home" digest)" "p-nm-custody-recovery" \
    "the declined proposal leaves the card"
  pass "proposal lane: a declined proposal is never proposed again"
}

test_accept_files_one_real_backlog_item_and_leaves_the_card() {
  local home work
  home=$(make_home accept)
  write_custody_evidence "$home"
  lane "$home" scan >/dev/null
  lane "$home" accept p-nm-custody-recovery >/dev/null || fail "accept failed"
  work=$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.work')
  [ -n "$work" ] && [ "$work" != null ] || fail "accept recorded no backlog item"
  assert_equals "accepted" "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.state')" \
    "the proposal records its decision"

  # The item is real ordinary work, addressable through the normal backlog path.
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" show "$work" >/dev/null \
    || fail "the accepted item is not in the backlog"
  assert_grep "$work" "$home/data/backlog.md" "the accepted item is a real backlog row"
  assert_grep "p-nm-custody-recovery" "$home/data/backlog.md" "the row names the proposal it came from"

  assert_equals "" "$(lane "$home" list --json | jq -c 'select(.id=="p-nm-custody-recovery")')" \
    "the accepted proposal leaves the open list"
  pass "proposal lane: accept files one real backlog item and leaves the card"
}

test_accept_links_an_existing_item_and_undoes_with_reopen() {
  local home work
  home=$(make_home link)
  write_custody_evidence "$home"
  lane "$home" scan >/dev/null
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" \
    add existing-item-1 "already filed work" --kind ship >/dev/null
  lane "$home" accept p-nm-custody-recovery --task existing-item-1 >/dev/null
  work=$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.work')
  assert_equals "existing-item-1" "$work" "accept can link an item the operator already filed"
  # A second accept must refuse rather than file duplicate work.
  if lane "$home" accept p-nm-custody-recovery >/dev/null 2>&1; then
    fail "accepting an accepted proposal must refuse"
  fi
  lane "$home" reopen p-nm-custody-recovery >/dev/null
  assert_equals "proposed" "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.state')" \
    "reopen undoes an acceptance"
  pass "proposal lane: accept links an existing item and reopen undoes it"
}

test_pause_silences_the_lane_and_resume_restores_it() {
  local home out
  home=$(make_home pause)
  write_custody_evidence "$home"
  lane "$home" scan >/dev/null
  lane "$home" pause >/dev/null
  assert_equals "true" "$(jq -r '.paused' "$home/config/proposals.json")" "pause is recorded durably"

  out=$(FM_PROPOSAL_INTERVAL=60 lane "$home" check)
  assert_equals "" "$out" "a paused lane never wakes anyone"
  if lane "$home" digest >/dev/null 2>&1; then
    fail "a paused lane must refuse the card"
  fi

  lane "$home" resume >/dev/null
  assert_equals "false" "$(jq -r '.paused' "$home/config/proposals.json")" "resume clears the flag"
  out=$(FM_PROPOSAL_INTERVAL=60 lane "$home" check)
  assert_contains "$out" "waiting for a decision" "a resumed lane wakes on its next cadence"
  pass "proposal lane: pause silences the lane and resume restores it"
}

test_check_fires_once_per_cadence() {
  local home first second
  home=$(make_home cadence)
  write_custody_evidence "$home"
  first=$(FM_PROPOSAL_INTERVAL=60 lane "$home" check)
  assert_contains "$first" "waiting for a decision" "the first due pass wakes once"
  second=$(FM_PROPOSAL_INTERVAL=60 lane "$home" check)
  assert_equals "" "$second" "the same cadence never wakes twice"
  # A lane with nothing open stays silent even when its cadence is due.
  lane "$home" decline p-nm-custody-recovery >/dev/null
  printf '%s\n' "1" > "$home/state/.proposal-lane-last-card"
  assert_equals "" "$(FM_PROPOSAL_INTERVAL=60 lane "$home" check)" \
    "a due cadence with nothing open stays silent"
  pass "proposal lane: the card fires once per cadence and never without a proposal"
}

test_card_is_bounded_and_carries_one_evidence_line_each() {
  local home out entries
  home=$(make_home card)
  write_custody_evidence "$home"
  # Enough distinct friction to exceed the card bound.
  {
    printf 'blocked: validation twice hit environment failures (actionlint unavailable)\n'
    printf 'blocked: gh preflight failed for the worker identity\n'
    printf 'blocked: gh preflight failed for the worker identity again\n'
    printf 'blocked: gh preflight failed for the worker identity once more\n'
    printf 'blocked: gh preflight failed for the worker identity a fourth time\n'
    printf 'blocked: the credential for the route is unavailable\n'
    printf 'blocked: the credential for the route is unavailable again\n'
  } > "$home/state/ccc.status"
  {
    printf '\n  hold-kind: captain\n'
    printf '\n  hold-kind: captain\n'
    printf '\n  hold-kind: captain\n'
    printf '\n  hold-kind: captain\n'
  } >> "$home/data/backlog.md"
  mkdir -p "$home/data/finished-a" "$home/data/finished-b" "$home/data/finished-c"
  printf 'x\nthe value is not verified\nthe second value is unverified\n' > "$home/data/finished-a/report.md"
  printf 'the value is not verified\nthe other value is unverified\n' > "$home/data/finished-b/report.md"
  printf 'the value is not verified\nnot verified again\n' > "$home/data/finished-c/report.md"

  out=$(FM_PROPOSAL_MAX=5 lane "$home" digest)
  entries=$(printf '%s\n' "$out" | grep -c '^\[[0-9]\] ')
  [ "$entries" -le 5 ] || fail "the card carried $entries proposals, more than its bound"
  [ "$entries" -ge 3 ] || fail "the card carried only $entries proposals with plenty open"
  assert_equals "1" "$(printf '%s\n' "$out" | grep -c '^\[1\] ')" "the first entry appears once"
  assert_equals "$entries" "$(printf '%s\n' "$out" | grep -c '    evidence: ')" \
    "each entry carries exactly one evidence line"
  assert_contains "$out" "more evidence line(s) with:" "the rest of the evidence is pointed at, not dumped"
  pass "proposal lane: the card is bounded to 3-5 proposals with one evidence line each"
}

test_read_only_commands_never_write_a_ledger() {
  local home
  home=$(make_home readonly)
  write_custody_evidence "$home"
  lane "$home" list >/dev/null
  lane "$home" status >/dev/null
  assert_absent "$home/data/proposals.jsonl" "list and status create no ledger"
  pass "proposal lane: list and status stay read-only"
}

test_malformed_configuration_is_refused() {
  local home
  home=$(make_home badconfig)
  printf 'paused = yes\n' > "$home/config/proposals.json"
  if lane "$home" status >/dev/null 2>&1; then
    fail "an unreadable config must be refused, not ignored"
  fi
  printf '{"interval": "soon"}\n' > "$home/config/proposals.json"
  if lane "$home" check >/dev/null 2>&1; then
    fail "a non-numeric cadence must be refused"
  fi
  pass "proposal lane: malformed configuration is refused"
}

test_arm_and_disarm_manage_the_watcher_check() {
  local home
  home=$(make_home arm)
  write_custody_evidence "$home"
  lane "$home" scan >/dev/null
  lane "$home" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/proposals.check.sh" "arm installs the check"
  assert_present "$home/state/proposals.check-trust" "arm binds the check bytes"
  assert_equals "700" "$(fm_pr_file_mode "$home/state/proposals.check.sh")" "the check is private"
  assert_contains "$(lane "$home" status)" "watcher check: registered" "status reports the wiring"

  # The installed shim is what the watcher runs, so it must work on its own.
  assert_contains "$(FM_PROPOSAL_INTERVAL=60 "$home/state/proposals.check.sh")" \
    "waiting for a decision" "the installed check runs the real check body"

  lane "$home" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/proposals.check.sh" "disarm removes the check"
  assert_absent "$home/state/proposals.check-trust" "disarm removes its binding"
  pass "proposal lane: arm and disarm manage the installed watcher check"
}

test_stale_evidence_supersedes_instead_of_re_proposing() {
  local home
  home=$(make_home stale)
  write_custody_evidence "$home"
  lane "$home" scan >/dev/null
  rm -f "$home/state/aaa.status" "$home/state/bbb.status"
  jq -c 'if .id == "p-nm-custody-recovery" then .last_seen_epoch = 1 else . end' \
    "$home/data/proposals.jsonl" > "$home/data/ledger.tmp"
  mv "$home/data/ledger.tmp" "$home/data/proposals.jsonl"
  FM_PROPOSAL_STALE_DAYS=1 lane "$home" scan >/dev/null
  assert_equals "superseded" "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.state')" \
    "a proposal whose evidence is gone is superseded, not dropped"
  # Its evidence survives the record it came from, so the decision stays reviewable.
  assert_contains "$(ledger "$home" 'select(.id=="p-nm-custody-recovery")|.evidence[0]')" \
    "state/aaa.status:2:" "the captured evidence outlives its source record"
  pass "proposal lane: stale evidence supersedes a proposal instead of re-proposing it"
}

test_a_catalog_typo_is_refused_rather_than_silently_ignored() {
  local home
  home=$(make_home catalog)
  write_custody_evidence "$home"
  printf '%s\n' 'broken-rule	nonsense	foo	1	1	firstmate	x	y	z' > "$home/bad-rules.tsv"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROPOSAL_RULES="$home/bad-rules.tsv" \
    "$LANE" scan >/dev/null 2>&1; then
    fail "a rule naming an unknown source must be refused"
  fi
  printf '%s\n' 'broken-rule	status	foo	nope	1	firstmate	x	y	z' > "$home/bad-rules.tsv"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROPOSAL_RULES="$home/bad-rules.tsv" \
    "$LANE" scan >/dev/null 2>&1; then
    fail "a rule with a non-numeric threshold must be refused"
  fi
  pass "proposal lane: a catalog typo is refused rather than silently ignored"
}

test_help_documents_every_subcommand() {
  local out
  out=$("$LANE" --help)
  assert_contains "$out" "observation pass" "help states what the lane is"
  assert_contains "$out" "never files work that was not" "help states the acceptance boundary"
  for sub in scan list show digest accept decline supersede reopen pause resume status check arm disarm; do
    assert_contains "$out" "fm-proposal-lane.sh $sub" "help documents $sub"
  done
  pass "proposal lane: help documents every subcommand and the acceptance boundary"
}

test_observation_pass_names_the_record_and_line_of_every_proposal
test_a_rule_below_its_threshold_proposes_nothing
test_emergent_family_is_proposed_and_a_claimed_one_is_skipped
test_declined_proposal_is_never_re_proposed
test_accept_files_one_real_backlog_item_and_leaves_the_card
test_accept_links_an_existing_item_and_undoes_with_reopen
test_pause_silences_the_lane_and_resume_restores_it
test_check_fires_once_per_cadence
test_card_is_bounded_and_carries_one_evidence_line_each
test_read_only_commands_never_write_a_ledger
test_malformed_configuration_is_refused
test_arm_and_disarm_manage_the_watcher_check
test_stale_evidence_supersedes_instead_of_re_proposing
test_a_catalog_typo_is_refused_rather_than_silently_ignored
test_help_documents_every_subcommand
