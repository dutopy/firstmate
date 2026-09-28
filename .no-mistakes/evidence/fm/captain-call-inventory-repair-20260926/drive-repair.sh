#!/usr/bin/env bash
# Live drive of fm-captain-hold.sh repair-inventory in an isolated FM_HOME.
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-repair-live.XXXXXX)
mkdir -p $H/data $H/state $H/config $H/projects $H/fakebin
cp "$ROOT/.tasks.toml" $H/.tasks.toml
printf '## In flight\n\n## Queued\n\n## Done\n' > $H/data/backlog.md
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > $H/fakebin/$t; chmod +x $H/fakebin/$t; done
cap() { echo "\$ fm-captain-hold.sh $*"; PATH="$H/fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config "$ROOT/bin/fm-captain-hold.sh" "$@"; echo "[exit $?]"; }
O=coauthor-line-audit; R=folium-coauthor-attribution
echo "=== Setup: real open Folium attribution captain call; audit meta wrongly lists itself"
cap hold $R --title "Choose Folium co-author attribution" --reason "captain attribution choice remains open" --repo folium
printf '%s\n' "done: audit finished" "needs-decision [key=$R]: choose Folium co-author attribution" > $H/state/$O.status
printf '%s\n' decisions_reviewed=1 decision_keys= "decision_keys=$O" > $H/state/$O.meta
mkdir -p $H/data/$O; echo "# coauthor-line-audit report: 12 commits audited" > $H/data/$O/report.md
echo "--- meta before:"; cat $H/state/$O.meta
echo; echo "=== S1 verify before repair (teardown gate)"; cap verify $O
echo; echo "=== S2 adversarial: erroneous id != origin"; cap repair-inventory $O some-other-task $R
echo; echo "=== S3 adversarial: real call == origin"; cap repair-inventory $O $O $O
echo; echo "=== S4 adversarial: named call is not captain-held"; cap repair-inventory $O $O not-a-held-task
echo; echo "=== S5 adversarial: no matching open decision on status"; cap hold other-held --title x --reason y --repo folium >/dev/null; cap repair-inventory $O $O other-held
echo; echo "--- meta unchanged after refusals:"; cat $H/state/$O.meta
echo; echo "=== S6 adversarial: unreviewed inventory"; cp $H/state/$O.meta $H/m.bak; printf 'decisions_reviewed=0\n' >> $H/state/$O.meta; cap repair-inventory $O $O $R; cp $H/m.bak $H/state/$O.meta
echo; echo "=== S7 adversarial: symlinked meta"; mv $H/state/$O.meta $H/real.meta; ln -s $H/real.meta $H/state/$O.meta; cap repair-inventory $O $O $R; rm $H/state/$O.meta; mv $H/real.meta $H/state/$O.meta
echo; echo "=== S8 happy path repair"; cap repair-inventory $O $O $R
echo "--- meta after:"; cat $H/state/$O.meta
echo "--- status after (Folium call wording):"; cat $H/state/$O.status
echo "--- report after:"; cat $H/data/$O/report.md
echo "--- real call still open:"; cap open $R
echo; echo "=== S9 re-run repair (entry already gone)"; cap repair-inventory $O $O $R
echo; echo "=== S10 verify after repair (still blocked by open Folium decision -> teardown refused)"; cap verify $O
echo; echo "=== S11 dotted slug: literal match keeps sibling"
printf '%s\n' "needs-decision [key=$R]: x" > $H/state/co.audit.status
printf '%s\n' decisions_reviewed=1 "decision_keys=co.audit,coxaudit" > $H/state/co.audit.meta
cap repair-inventory co.audit co.audit $R; echo "--- meta after:"; cat $H/state/co.audit.meta
rm -rf $H
