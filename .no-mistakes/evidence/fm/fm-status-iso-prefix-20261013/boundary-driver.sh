#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot iso-boundaries)
mkdir -p "$TMP_ROOT/state"
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
fm_write_meta "$TMP_ROOT/state/produit.meta" kind=secondmate
status="$TMP_ROOT/state/produit.status"
printf '%s\n' 'needs-decision: [key=x] keep this open' > "$status"
for line in \
 '2026-11-03T04:51:49Z done' \
 '2026-11-03T04:51:49Z note: resolved: [key=x] merely prose' \
 'prefix 2026-11-03T04:51:49Z resolved: [key=x] not leading' \
 '2026-11-03T04:51:49Z prose resolved: [key=x] not leading' \
 '2026-11-03T04:51:49Zresolved: [key=x] no separator' \
 '2026-11-03T04:51Z resolved: [key=x] incomplete timestamp'; do
 printf '%s\n' "$line" >> "$status"
 printf '\nAppend adversarial input: %s\n$ fm-wake-drain.sh\n' "$line"
 out=$("$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
 printf '%s\n' "$out"
 assert_contains "$out" 'produit [key=x] needs-decision: keep this open' 'adversarial text must not resolve x'
done
printf '%s\n' '2026-11-03T04:51:49Z resolved [key=x]: accepted' >> "$status"
printf '\nAppend valid timestamped before-colon resolution\n$ fm-wake-drain.sh\n'
out=$("$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
printf '%s\n' "$out"
assert_not_contains "$out" 'OPEN DECISIONS' 'valid resolution must close x'
printf '%s\n' '2026-11-03T04:54:00Z needs-decision [key=before]: [key=after] preserve note: with colon' >> "$status"
printf '\nAppend timestamped decision with competing key positions\n$ fm-wake-drain.sh\n'
out=$("$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
printf '%s\n' "$out"
assert_contains "$out" 'produit [key=before] needs-decision: [key=after] preserve note: with colon' 'before-colon key wins without consuming note text'
