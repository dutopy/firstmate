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

for declaration in \
  'done: PR https://example.com/pr/1' \
  'done [key=fix]: ready' \
  'done: [key=fix] ready' \
  $' \tdone: ready' \
  'done [corr=0123456789abcdef] [key=fix]: ready' \
  'done corr=0123456789abcdef [key=fix]: ready'; do
  printf 'working: fixing\n%s\n verification finished\n checks green\n\n' "$declaration" >"$TMP_ROOT/event.status"
  "$SCRIPT" --status "$TMP_ROOT/event.status" "$TMP_ROOT/absent.proof" >/dev/null 2>&1
  expect_code 1 $? "done event requires proof: $declaration"
  "$SCRIPT" --status "$TMP_ROOT/event.status" "$TMP_ROOT/missing.proof" >/dev/null 2>&1
  expect_code 1 $? "done event rejects incomplete proof: $declaration"
  "$SCRIPT" --status "$TMP_ROOT/event.status" "$TMP_ROOT/workaround.proof" >/dev/null 2>&1
  expect_code 1 $? "done event rejects workaround proof: $declaration"
  "$SCRIPT" --status "$TMP_ROOT/event.status" "$TMP_ROOT/complete.proof" >/dev/null 2>&1
  expect_code 0 $? "done event accepts complete proof: $declaration"
  printf 'working: follow-up\n continuation\n' >>"$TMP_ROOT/event.status"
  "$SCRIPT" --status "$TMP_ROOT/event.status" "$TMP_ROOT/absent.proof" >/dev/null 2>&1
  expect_code 0 $? "later working event supersedes done: $declaration"
done
pass "shared status event grammar requires proof for every done representation"

for key in root_cause regression_test retest authoritative_state artifact_or_scope rollback status; do
  if [ "$key" = status ]; then
    values=(workaround)
  else
    values=(unknown n/a none na '?' TODO TBD)
  fi
  for value in "${values[@]}"; do
    for ending in $' \t' $'\r'; do
      sed "/^${key}:/d" "$TMP_ROOT/complete.proof" >"$TMP_ROOT/padded.proof"
      printf '%s: \t%s%s\n' "$key" "$value" "$ending" >>"$TMP_ROOT/padded.proof"
      "$SCRIPT" "$TMP_ROOT/padded.proof" >/dev/null 2>&1
      expect_code 1 $? "padded $key=$value is refused"
      "$SCRIPT" --status "$TMP_ROOT/b.status" "$TMP_ROOT/padded.proof" >/dev/null 2>&1
      expect_code 1 $? "done with padded $key=$value is refused"
    done
  done
done
pass "padded placeholders and workaround refused through both interfaces"

sed $'s/$/\r/' "$TMP_ROOT/complete.proof" >"$TMP_ROOT/crlf.proof"
"$SCRIPT" "$TMP_ROOT/crlf.proof" >/dev/null 2>&1
expect_code 0 $? "complete CRLF packet is accepted"
"$SCRIPT" --status "$TMP_ROOT/b.status" "$TMP_ROOT/crlf.proof" >/dev/null 2>&1
expect_code 0 $? "done with complete CRLF packet passes"
pass "complete CRLF packet accepted through both interfaces"

mkdir -p "$TMP_ROOT/firstmate scripts" "$TMP_ROOT/worker"
cp "$ROOT/bin/fm-dod-lib.sh" "$SCRIPT" "$TMP_ROOT/firstmate scripts/"
for mode in direct-PR local-only no-mistakes; do
  rendered=$(cd "$TMP_ROOT/worker" && . "$TMP_ROOT/firstmate scripts/fm-dod-lib.sh" && fm_dod_block "$mode" proof-test)
  command=$(printf '%s\n' "$rendered" | sed -n "s/^Before any 'done:'.* and make \(.*\) <packet> pass;.*/\1/p")
  [ -n "$command" ] || fail "missing proof command for $mode"
  (cd "$TMP_ROOT/worker" && bash -c "$command \"\$1\"" _ "$TMP_ROOT/complete.proof") >/dev/null 2>&1
  expect_code 0 $? "$mode proof command works outside Firstmate with spaces in its path"
  (cd "$TMP_ROOT/worker" && bash -c "$command \"\$1\"" _ "$TMP_ROOT/workaround.proof") >/dev/null 2>&1
  expect_code 1 $? "$mode proof command refuses a workaround"
done
pass "all delivery modes emit executable cross-project proof commands"

printf 'done: PR https://example.com/pr/1\n checks green\n' >"$TMP_ROOT/green-continuation.status"
"$SCRIPT" --status "$TMP_ROOT/green-continuation.status" "$TMP_ROOT/absent.proof" >/dev/null 2>&1
expect_code 1 $? "checks-green continuation must not bypass done proof requirement"
pass "checks-green continuation retains the done proof requirement"
