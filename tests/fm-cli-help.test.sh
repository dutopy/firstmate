#!/usr/bin/env bash
# Tests for bin/fm-cli-lib.sh and the inert --help contract every firstmate
# command shares: `--help` prints usage and exits 0 without taking a lock,
# writing state, appending a status line, or contacting the network.
#
# The sweep runs each command in a disposable home and proves the whole
# sandbox is byte-for-byte unchanged after the help call. bin/fm-lock.sh gets
# the sharper assertion the captain asked for: no lock file is created and the
# exit code is the help code, never an acquire result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cli-help-tests)

# Every mutating command that lacked an inert --help path. Read-only commands
# are included too, because the same guarantee costs nothing and a help path
# that cannot mutate is simpler to reason about than one that sometimes can.
MUTATING_COMMANDS=(
  fm-agy-trust.sh
  fm-backlog-handoff.sh
  fm-backlog-receive.sh
  fm-bootstrap.sh
  fm-branch-outcome.sh
  fm-branch-prompt.sh
  fm-busy-event.sh
  fm-check-register.sh
  fm-check-unregister.sh
  fm-claude-stop-autoarm.sh
  fm-claude-trust.sh
  fm-crew-state.sh
  fm-doc-audience-check.sh
  fm-ensure-agents-md.sh
  fm-extension.sh
  fm-fleet-sync.sh
  fm-guard.sh
  fm-harness.sh
  fm-herdr-ci-cleanup.sh
  fm-herdr-session-cleanup.sh
  fm-home-seed.sh
  fm-install-actionlint.sh
  fm-install-herdr.sh
  fm-install-shellcheck.sh
  fm-install-treehouse.sh
  fm-lease.sh
  fm-lock.sh
  fm-mail.sh
  fm-merge-local.sh
  fm-on.sh
  fm-peek.sh
  fm-pr-check.sh
  fm-pr-merge.sh
  fm-procevent-lavish.sh
  fm-procevent-quota.sh
  fm-procevent-remote-reply.sh
  fm-procevent.sh
  fm-procevent-when.sh
  fm-project-mode.sh
  fm-promote.sh
  fm-pr-poll.sh
  fm-quota-choose.sh
  fm-remote-delta-read.sh
  fm-remote-doctor.sh
  fm-remote-entrypoint.sh
  fm-remote-file.sh
  fm-remote-herdr-guard.sh
  fm-remote-home-provision.sh
  fm-remote-home-seed.sh
  fm-remote-inherit-push.sh
  fm-remote-inherit.sh
  fm-remote-job-worker.sh
  fm-remote-secondmate-control.sh
  fm-review-diff.sh
  fm-secondmate-report.sh
  fm-send.sh
  fm-sessionstart-cursor.sh
  fm-sessionstart-nudge.sh
  fm-sessionstart-run.sh
  fm-supervise-daemon.sh
  fm-teardown.sh
  fm-test-isolation-proof.sh
  fm-test-run.sh
  fm-turnend-guard-cursor.sh
  fm-turnend-guard-grok.sh
  fm-turnend-guard.sh
  fm-update.sh
  fm-wake-drain.sh
  fm-wake-grant.sh
  fm-watch-arm.sh
  fm-watch.sh
  fm-x-dismiss.sh
  fm-x-link.sh
  fm-x-poll.sh
)

# sandbox <name>: a disposable home and state tree whose untouched signature the
# help run must leave alone.
sandbox() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data" "$dir/home/config" "$dir/home/projects" "$dir/state"
  printf '%s\n' "$dir"
}

snapshot() {
  find "$1" -mindepth 1 2>/dev/null | LC_ALL=C sort
}

# run_help <script>: run one command's --help against the disposable home. The
# stdout/stderr files live outside the sandbox so the run's own plumbing cannot
# count as a mutation. Echoes the exit code.
run_help() {
  local script=$1 dir=$2
  (
    cd "$ROOT" || exit 1
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" \
      "$ROOT/bin/$script" --help \
      > "$dir.help.out" 2> "$dir.help.err"
  )
  printf '%s\n' "$?"
}

test_help_is_inert_for_every_listed_command() {
  local script dir rc before after
  for script in "${MUTATING_COMMANDS[@]}"; do
    dir=$(sandbox "${script%.sh}")
    before=$(snapshot "$dir")
    rc=$(run_help "$script" "$dir")
    after=$(snapshot "$dir")
    [ "$rc" -eq 0 ] \
      || fail "$script --help exited $rc, not the help code: $(cat "$dir.help.err" 2>/dev/null | tail -1)"
    [ -s "$dir.help.out" ] || fail "$script --help printed no usage"
    [ "$before" = "$after" ] \
      || fail "$script --help mutated its home: $(printf '%s\n' "$after" | grep -vxF "$before" | tr '\n' ' ')"
  done
  pass "every mutating command answers --help without touching state"
}

test_lock_help_never_acquires_or_creates_the_lock() {
  local dir lock rc before after
  dir=$(sandbox fm-lock-the-lock-path)
  lock="$dir/state/.lock"
  before=$(snapshot "$dir")
  rc=$(run_help fm-lock.sh "$dir")
  after=$(snapshot "$dir")

  [ "$rc" -eq 0 ] || fail "fm-lock.sh --help exited $rc, not the help code"
  assert_grep 'Usage:' "$dir.help.out" "fm-lock.sh --help did not print usage"
  assert_absent "$lock" "fm-lock.sh --help created the session lock"
  [ "$before" = "$after" ] \
    || fail "fm-lock.sh --help changed the state tree: $(printf '%s\n' "$after" | grep -vxF "$before" | tr '\n' ' ')"
  pass "fm-lock.sh --help prints usage, exits 0, and never takes or creates the lock"
}

test_lock_help_creates_no_state_directory() {
  local dir rc
  dir="$TMP_ROOT/fm-lock-no-state"
  mkdir -p "$dir/home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    "$ROOT/bin/fm-lock.sh" --help > "$dir.help.out" 2> "$dir.help.err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lock.sh --help exited $rc with a fresh state path"
  assert_absent "$dir/state" \
    "fm-lock.sh --help created the state directory its acquire path would make"
  pass "fm-lock.sh --help does not even create the state directory"
}

test_lock_help_beats_a_missing_harness_ancestry() {
  local dir rc
  dir=$(sandbox fm-lock-help-before-ancestry)
  # The acquire path locates a harness process in the shell ancestry and exits 1
  # when it cannot. Help must answer first, so no such lookup can run.
  rc=$(run_help fm-lock.sh "$dir")
  [ "$rc" -eq 0 ] || fail "fm-lock.sh --help depended on an acquire-path lookup (exit $rc)"
  assert_no_grep 'cannot locate harness process' "$dir.help.err" \
    "fm-lock.sh --help reached the harness-ancestry lookup"
  pass "fm-lock.sh --help answers before the harness-ancestry acquire path"
}

test_bootstrap_help_writes_nothing_and_calls_no_forge_tool() {
  local dir rc before after tool
  dir=$(sandbox fm-bootstrap-help)
  # The reported defect: --help used to run the whole bootstrap, materializing
  # config/startup-memory-budget and calling gh and gh-axi. The fakes make any
  # forge or network call visible instead of merely assumed absent.
  mkdir -p "$dir/fakebin"
  for tool in gh gh-axi; do
    cat > "$dir/fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$0 \$*" >> "$dir/forge.log"
exit 1
SH
    chmod +x "$dir/fakebin/$tool"
  done
  before=$(snapshot "$dir")
  (
    cd "$ROOT" || exit 1
    PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" \
      "$ROOT/bin/fm-bootstrap.sh" --help > "$dir.help.out" 2> "$dir.help.err"
  )
  rc=$?
  after=$(snapshot "$dir")

  [ "$rc" -eq 0 ] || fail "fm-bootstrap.sh --help exited $rc, not the help code"
  assert_grep 'Usage:' "$dir.help.out" "fm-bootstrap.sh --help did not print usage"
  assert_absent "$dir/home/config/startup-memory-budget" \
    "fm-bootstrap.sh --help fell into the bootstrap path and wrote its config"
  assert_absent "$dir/forge.log" "fm-bootstrap.sh --help contacted the forge or the network"
  [ "$before" = "$after" ] \
    || fail "fm-bootstrap.sh --help changed the sandbox: $(printf '%s\n' "$after" | grep -vxF "$before" | tr '\n' ' ')"
  pass "fm-bootstrap.sh --help answers before the bootstrap path, offline and unchanged"
}

test_cli_help_ignores_every_argument_but_the_first() {
  local out rc
  out=$(
    FM_ROOT_OVERRIDE="$ROOT" bash -c '
      . "$1/bin/fm-cli-lib.sh"
      fm_cli_help status --help
      printf "reached-past-help\n"
    ' _ "$ROOT" 2>&1
  )
  rc=$?
  [ "$rc" -eq 0 ] || fail "fm_cli_help with a non-help first argument exited $rc"
  assert_contains "$out" 'reached-past-help' \
    "fm_cli_help consumed a later --help instead of only the first argument"
  pass "fm_cli_help triggers only on the first argument"
}

test_help_is_inert_for_every_listed_command
test_lock_help_never_acquires_or_creates_the_lock
test_lock_help_creates_no_state_directory
test_lock_help_beats_a_missing_harness_ancestry
test_bootstrap_help_writes_nothing_and_calls_no_forge_tool
test_cli_help_ignores_every_argument_but_the_first
