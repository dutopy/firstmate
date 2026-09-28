#!/usr/bin/env bash
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-repair-live2.XXXXXX)
mkdir -p $H/data $H/state $H/config $H/projects $H/fakebin
cp "$ROOT/.tasks.toml" $H/.tasks.toml
printf '## In flight\n\n## Queued\n\n## Done\n' > $H/data/backlog.md
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > $H/fakebin/$t; chmod +x $H/fakebin/$t; done
cap() { echo "\$ fm-captain-hold.sh $*"; PATH="$H/fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config "$ROOT/bin/fm-captain-hold.sh" "$@"; echo "[exit $?]"; }
O=coauthor-line-audit; R=folium-coauthor-attribution
cap hold $R --title "Choose Folium co-author attribution" --reason "captain attribution choice remains open" --repo folium >/dev/null
printf '%s\n' "needs-decision [key=$R]: choose Folium co-author attribution" > $H/state/$O.status
printf '%s\n' decisions_reviewed=1 "decision_keys=$O" > $H/state/$O.meta
mkdir -p $H/data/$O; echo "# report" > $H/data/$O/report.md
cap repair-inventory $O $O $R
cap complete $O $R
echo "--- meta:"; cat $H/state/$O.meta
cap verify $O
echo "--- Folium call still open after complete+verify:"; cap open $R
echo "--- report:"; cat $H/data/$O/report.md
rm -rf $H
