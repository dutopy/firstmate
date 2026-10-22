#!/usr/bin/env bash
# Behavior tests for bin/fm-done-proof.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/bin/fm-done-proof.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-proof)

cat >"$TMP_ROOT/complete.proof" <<'EOF'
root_cause: restart masked sustained CPU use by the tunnel daemon
regression_test: tests/tailscale-cpu.test.sh
retest: 3 consecutive green runs
authoritative_state: process table re-read after change
artifact_or_scope: tailscaled on the iMac only
rollback: git revert the commit
EOF

"$SCRIPT" "$TMP_ROOT/complete.proof" >/dev/null 2>&1
expect_code 0 $? "complete packet is accepted"
pass "complete packet accepted"

sed '/^regression_test:/d' "$TMP_ROOT/complete.proof" >"$TMP_ROOT/missing.proof"
err=$("$SCRIPT" "$TMP_ROOT/missing.proof" 2>&1 >/dev/null)
expect_code 1 $? "missing regression test is refused"
case "$err" in *regression_test*) ;; *) fail "refusal must name regression_test, got: $err" ;; esac
pass "missing regression test refused and named"

sed 's/^rollback:.*/rollback: TODO/' "$TMP_ROOT/complete.proof" >"$TMP_ROOT/placeholder.proof"
"$SCRIPT" "$TMP_ROOT/placeholder.proof" >/dev/null 2>&1
expect_code 1 $? "placeholder rollback is refused"
pass "placeholder value refused"

{ cat "$TMP_ROOT/complete.proof"; echo "status: workaround"; } >"$TMP_ROOT/workaround.proof"
"$SCRIPT" "$TMP_ROOT/workaround.proof" >/dev/null 2>&1
expect_code 1 $? "workaround is not a resolution"
pass "workaround refused as done"

"$SCRIPT" "$TMP_ROOT/absent.proof" >/dev/null 2>&1
expect_code 2 $? "absent file is a usage error"
pass "absent file is a usage error"

printf 'working: x\n' >"$TMP_ROOT/a.status"
"$SCRIPT" --status "$TMP_ROOT/a.status" "$TMP_ROOT/absent.proof" >/dev/null 2>&1
expect_code 0 $? "non-done status passes the gate"
pass "gate ignores non-done status"

printf 'working: x\ndone: PR u\n' >"$TMP_ROOT/b.status"
"$SCRIPT" --status "$TMP_ROOT/b.status" "$TMP_ROOT/absent.proof" >/dev/null 2>&1
expect_code 1 $? "done without packet is refused"
pass "done without packet refused"

"$SCRIPT" --status "$TMP_ROOT/b.status" "$TMP_ROOT/missing.proof" >/dev/null 2>&1
expect_code 1 $? "done with incomplete packet is refused"
pass "done with incomplete packet refused"

"$SCRIPT" --status "$TMP_ROOT/b.status" "$TMP_ROOT/complete.proof" >/dev/null 2>&1
expect_code 0 $? "done with complete packet passes"
pass "done with complete packet passes"
