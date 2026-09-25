#!/usr/bin/env bash
# Behavioral coverage for the bounded AXI error/log/hook projection.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-axi-diagnostics)
HOME_DIR="$TMP_ROOT/home"
AXI="$ROOT/bin/fm-axi-status.sh"
mkdir -p "$HOME_DIR/state"
export FM_HOME="$HOME_DIR"

"$AXI" diagnostics --help > "$TMP_ROOT/help" || fail "diagnostics help failed"
grep -F 'six bounded error/log/hook targets' "$TMP_ROOT/help" >/dev/null || fail "help omitted bounded target contract"

printf 'triage\n' > "$HOME_DIR/state/.watch-triage.log"
printf 'exit\n' > "$HOME_DIR/state/.watch-cycle-exits.log"
printf 'delivery\n' > "$HOME_DIR/state/.watch-deliveries.log"
printf 'poll failed\n' > "$HOME_DIR/state/x-poll.error"
BEFORE_TRIAGE=$(sha256sum "$HOME_DIR/state/.watch-triage.log")

FULL=$("$AXI" diagnostics --full) || fail "full diagnostics failed"
[ "$(printf '%s\n' "$FULL" | grep -c '^axi-output.v1 target=')" -eq 6 ] \
  || fail "diagnostics did not expose exactly six targets"
printf '%s\n' "$FULL" | grep -F 'target=state/.watch-triage.log' >/dev/null || fail "triage target missing"
printf '%s\n' "$FULL" | grep -F 'target=state/x-poll.error' >/dev/null || fail "poll error target missing"
printf '%s\n' "$FULL" | grep -F 'target=bin/fm-hook-host-lib.sh' >/dev/null || fail "host hook target missing"
printf '%s\n' "$FULL" | grep -F 'target=bin/fm-kimi-turnend-hook.sh' >/dev/null || fail "Kimi hook target missing"
printf '%s\n' "$FULL" | grep -F 'frequency=unknown' >/dev/null || fail "unknown runtime frequency was not disclosed"

COMPACT=$("$AXI" diagnostics --width 20) || fail "compact diagnostics failed"
while IFS= read -r line; do [ "${#line}" -le 20 ] || fail "line exceeds width: $line"; done <<< "$COMPACT"
printf '%s\n' "$COMPACT" | grep -F 'details=omitted;' >/dev/null \
  || fail "compact output omitted full-details route"
printf '%s\n' "$COMPACT" | grep -F 'command=' >/dev/null \
  || fail "compact output omitted diagnostics command route"
[ "$BEFORE_TRIAGE" = "$(sha256sum "$HOME_DIR/state/.watch-triage.log")" ] \
  || fail "diagnostics rewrote legacy log"

expect_fail() { if "$@" >"$TMP_ROOT/unexpected.out" 2>"$TMP_ROOT/unexpected.err"; then fail "expected failure: $*"; fi; }
expect_fail "$AXI" diagnostics --width 19
expect_fail "$AXI" diagnostics --unknown
pass "axi diagnostics preserves six legacy error/log/hook targets and reports runtime frequency as unknown"
