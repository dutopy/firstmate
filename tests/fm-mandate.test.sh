#!/usr/bin/env bash
# Tests for bin/fm-mandate.sh: the owner of standing-mandate records. Each case
# drives the public subcommands (grant, list, show, revoke, check, relay) in a
# throwaway home and asserts the verdicts and messages a caller relies on.
# The merge-path refusals that cite a mandate live in tests/fm-pr-merge.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANDATE="$ROOT/bin/fm-mandate.sh"
TMP_ROOT=$(fm_test_tmproot fm-mandate-tests)

epoch_to_iso_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

in_hours() {
  epoch_to_iso_utc $(($(date -u +%s) + $1 * 3600))
}

make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

mandate() {  # home args...
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$MANDATE" "$@"
}

run_capture() {  # home args... ; sets RC, OUT, ERR
  local home=$1
  shift
  set +e
  mandate "$home" "$@" > "$home/out" 2> "$home/err"
  RC=$?
  set -e
  OUT=$(cat "$home/out")
  ERR=$(cat "$home/err")
}

test_grant_requires_an_expiry_with_timezone() {
  local home
  home=$(make_home grant-validation)
  run_capture "$home" grant --id night --granted-by captain --action merge --repo 'acme/*'
  expect_code 2 "$RC" "grant without --expires-at must be a usage error"
  assert_contains "$ERR" "a mandate without an expiry is never recorded" "missing-expiry message"

  run_capture "$home" grant --id night --granted-by captain --action merge --repo 'acme/*' \
    --expires-at 2099-11-01T07:00:00
  expect_code 2 "$RC" "an expiry without a timezone must be refused"
  assert_contains "$ERR" "explicit timezone" "timezone message"

  run_capture "$home" grant --id night --granted-by captain --action merge --repo 'acme/*' \
    --expires-at 2099-02-30T07:00:00Z
  expect_code 2 "$RC" "an impossible date must be refused"

  run_capture "$home" grant --id night --granted-by captain --action merge --repo 'acme/*' \
    --expires-at 2020-01-01T07:00:00+01:00
  expect_code 1 "$RC" "an expiry in the past must be refused"
  assert_contains "$ERR" "is not in the future" "past-expiry message"
  [ ! -e "$home/state/mandates/night.mandate" ] || fail "a refused grant left a record behind"

  run_capture "$home" grant --id night --granted-by captain --action merge --repo 'acme/*' \
    --expires-at 2099-11-01T07:00:00+01:00
  expect_code 0 "$RC" "a valid grant must succeed"
  assert_contains "$OUT" "2099-11-01T06:00:00Z" "grant echoes the UTC instant"

  run_capture "$home" grant --id night --granted-by captain --action merge --repo 'acme/*' \
    --expires-at 2099-11-01T07:00:00+01:00
  expect_code 1 "$RC" "a duplicate id must be refused"
  pass "grant records only a future expiry with an explicit timezone and never overwrites"
}

test_check_enforces_action_repo_branch_and_paths() {
  local home
  home=$(make_home check-scope)
  mandate "$home" grant --id lots --granted-by captain --expires-at "$(in_hours 8)" \
    --action merge --repo 'acme/*' --branch main --deny-path 'ui/*' \
    --condition 'CI green' --condition 'real tests passed' >/dev/null

  run_capture "$home" check lots --action merge --repo acme/api --branch main --file src/a.go
  expect_code 0 "$RC" "an in-scope merge must pass"
  assert_contains "$OUT" "mandate lots in force until" "in-force verdict"

  run_capture "$home" check lots --action deliver --repo acme/api --branch main --file src/a.go
  expect_code 1 "$RC" "an action outside the mandate must refuse"
  assert_contains "$ERR" "action deliver is not allowed" "action refusal"

  run_capture "$home" check lots --action merge --repo other/api --branch main --file src/a.go
  expect_code 1 "$RC" "a repository outside the mandate must refuse"

  run_capture "$home" check lots --action merge --repo api --host acme --branch main --file src/a.go
  expect_code 0 "$RC" "a host-qualified repository match must pass"

  run_capture "$home" check lots --action merge --repo acme/api --branch release --file src/a.go
  expect_code 1 "$RC" "a base branch outside the mandate must refuse"
  assert_contains "$ERR" "base branch release is outside" "branch refusal"

  printf '%s\n' src/a.go ui/deep/button.css > "$home/paths"
  run_capture "$home" check lots --action merge --repo acme/api --branch main --files-from "$home/paths"
  expect_code 1 "$RC" "a denied path must refuse"
  assert_contains "$ERR" "changed path ui/deep/button.css is excluded" "path refusal"

  run_capture "$home" check lots --action merge --repo acme/api --branch main
  expect_code 1 "$RC" "path rules without a path list must refuse"
  assert_contains "$ERR" "coverage cannot be proven" "unprovable-coverage refusal"

  run_capture "$home" check absent --action merge --repo acme/api
  expect_code 1 "$RC" "an absent mandate must refuse"
  assert_contains "$ERR" "no standing authority applies" "absent refusal"
  pass "check refuses any action, repository, branch, or path the mandate does not cover"
}

test_expired_and_revoked_mandates_grant_nothing() {
  local home
  home=$(make_home lapse)
  mandate "$home" grant --id short --granted-by captain --expires-at "$(epoch_to_iso_utc $(($(date -u +%s) + 2)))" \
    --action merge --repo 'acme/*' >/dev/null
  mandate "$home" grant --id long --granted-by captain --expires-at "$(in_hours 8)" \
    --action merge --repo 'acme/*' >/dev/null
  sleep 3

  run_capture "$home" check short --action merge --repo acme/api
  expect_code 1 "$RC" "an expired mandate must refuse"
  assert_contains "$ERR" "its authority has lapsed even if its conditions still hold" "expiry refusal"

  run_capture "$home" relay short
  expect_code 1 "$RC" "an expired mandate must not be relayed"

  run_capture "$home" list
  assert_contains "$OUT" "long active" "list shows the active mandate"
  case "$OUT" in *short*) fail "plain list showed an expired mandate" ;; esac
  run_capture "$home" list --all
  assert_contains "$OUT" "short expired" "list --all shows the expired mandate"

  run_capture "$home" revoke long --by captain
  expect_code 0 "$RC" "revoke must succeed"
  run_capture "$home" check long --action merge --repo acme/api
  expect_code 1 "$RC" "a revoked mandate must refuse"
  assert_contains "$ERR" "was revoked at" "revocation refusal"
  pass "expired and revoked mandates refuse every check and are never relayed"
}

test_relay_carries_the_expiry_and_reproduces_the_mandate() {
  local home child exp cmd args
  home=$(make_home relay-parent)
  child=$(make_home relay-child)
  exp=$(in_hours 6)
  mandate "$home" grant --id night --granted-by captain --expires-at "$exp" \
    --action merge --repo 'acme/*' --deny-path 'ui/*' --condition 'no UI files touched' >/dev/null

  run_capture "$home" relay night
  expect_code 0 "$RC" "relay of an active mandate must succeed"
  assert_contains "$OUT" "expires_at: $exp" "relay states expires_at verbatim"
  assert_contains "$OUT" "condition: no UI files touched" "relay carries the conditions"
  assert_contains "$OUT" "--mandate night" "relay tells the receiver to cite the mandate"

  cmd=$(printf '%s\n' "$OUT" | sed -n 's/^  bin\/fm-mandate.sh //p')
  [ -n "$cmd" ] || fail "relay did not print the receiving grant command"
  eval "args=($cmd)"
  mandate "$child" "${args[@]}" >/dev/null || fail "the relayed grant command did not record the mandate"
  run_capture "$child" show night
  assert_contains "$OUT" "expires_at=$exp" "the relayed record keeps the same expiry"
  assert_contains "$OUT" "relayed_via=relay-parent" "the relayed record names the relaying home"
  assert_contains "$OUT" "deny_path=ui/*" "the relayed record keeps the path rule"
  pass "a relayed mandate always carries its expiry and reproduces the same scope"
}

test_grant_requires_an_expiry_with_timezone
test_check_enforces_action_repo_branch_and_paths
test_expired_and_revoked_mandates_grant_nothing
test_relay_carries_the_expiry_and_reproduces_the_mandate
