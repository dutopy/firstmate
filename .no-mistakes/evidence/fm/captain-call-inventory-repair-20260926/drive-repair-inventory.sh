#!/bin/bash
# Live driver: isolated FM home, real bin/fm-captain-hold.sh + bin/fm-teardown.sh + real tasks-axi.
set -u
ROOT=${ROOT:?}
T=$(mktemp -d /tmp/fm-repair-live.XXXXXX)
home=$T/home
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample" "$home/fakebin"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi herdr; do printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"; done
ln -s /bin/bash "$home/fakebin/bash"   # stock bash 3.2 (host Homebrew bash segfaults)
export PATH="$home/fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config"
CH="$ROOT/bin/fm-captain-hold.sh"
run() { echo "\$ $*"; "$@"; rc=$?; echo "[exit $rc]"; echo; return $rc; }
O=coauthor-line-audit R=folium-coauthor-attribution
echo "=== setup: finished audit workspace whose inventory wrongly records itself; Folium call open ==="
run "$CH" hold $R --title "Choose Folium co-author attribution" --reason "captain has not answered the attribution choice" --repo sample
cat > "$home/state/$O.meta" <<M
window=firstmate:fm-$O
worktree=$home/projects/missing-$O
project=$home/projects/sample
harness=codex
kind=scout
mode=scout
spawn_gen=fixture-$O
decisions_reviewed=1
decision_keys=$O
M
printf 'done: audit complete\nneeds-decision [key=%s]: choose Folium co-author attribution\n' $R > "$home/state/$O.status"
mkdir -p "$home/data/$O"; printf '# Co-author line audit\n\nFindings retained.\n' > "$home/data/$O/report.md"
cp "$home/state/$O.status" $T/status.before; cp "$home/data/$O/report.md" $T/report.before
echo "--- meta before"; cat "$home/state/$O.meta"; echo
echo "=== S1: verify blocks teardown before repair ==="; run "$CH" verify $O
echo "=== S1b: non-forced teardown refuses before repair ==="; run "$ROOT/bin/fm-teardown.sh" $O
echo "=== ADV: too few args ==="; run "$CH" repair-inventory $O $O
echo "=== ADV: mismatched erroneous id ==="; run "$CH" repair-inventory $O other-task $R
echo "=== ADV: real call == origin ==="; run "$CH" repair-inventory $O $O $O
echo "=== ADV: real call not captain-held ==="; run "$CH" repair-inventory $O $O not-a-held-task
echo "--- meta unchanged after refusals"; grep '^decision_keys=' "$home/state/$O.meta"; echo
echo "=== S2: repair-inventory ==="; run "$CH" repair-inventory $O $O $R
echo "--- meta after repair"; cat "$home/state/$O.meta"; echo
echo "=== S3: Folium call still open, wording+report unchanged ==="
run "$CH" open $R
(cd "$home" && tasks-axi show $R --full --file "$home/data/backlog.md") | grep -E 'state:|hold_kind|title' ; echo
cmp "$home/state/$O.status" $T/status.before && echo "status wording unchanged"
cmp "$home/data/$O/report.md" $T/report.before && echo "report unchanged"; echo
echo "=== ADV: repeat repair (already repaired) ==="; run "$CH" repair-inventory $O $O $R
echo "=== S4: verify still blocks until complete ==="; run "$CH" verify $O
echo "=== S5: follow printed next step ==="; run "$CH" complete $O $R; run "$CH" verify $O
echo "=== S6: non-forced teardown removes workspace, keeps report, Folium call stays open ==="
run "$ROOT/bin/fm-teardown.sh" $O
ls "$home/state/$O.meta" 2>&1; ls "$home/data/$O/report.md" && cat "$home/data/$O/report.md"
run "$CH" open $R
(cd "$home" && tasks-axi show $R --full --file "$home/data/backlog.md") | grep -E 'state:|hold_kind'
echo "=== ADV: dotted origin literal + two decision_keys lines ==="
"$CH" hold other-open --title x --reason y --repo sample >/dev/null
printf 'needs-decision [key=other-open]: q\n' > "$home/state/a.b.status"
printf 'decisions_reviewed=1\ndecision_keys=\ndecision_keys=a.b,axb\n' > "$home/state/a.b.meta"
run "$CH" repair-inventory a.b a.b other-open; cat "$home/state/a.b.meta"; echo
echo "=== ADV: unreviewed meta ==="
printf 'needs-decision [key=other-open]: q\n' > "$home/state/u.status"; printf 'decision_keys=u\n' > "$home/state/u.meta"
run "$CH" repair-inventory u u other-open
echo "=== ADV: no matching open decision on origin status ==="
printf 'done: nothing open\n' > "$home/state/n.status"; printf 'decisions_reviewed=1\ndecision_keys=n\n' > "$home/state/n.meta"
run "$CH" repair-inventory n n other-open
echo "=== ADV: symlinked meta ==="
printf 'decisions_reviewed=1\ndecision_keys=s\n' > $T/s.real; ln -s $T/s.real "$home/state/s.meta"; printf 'needs-decision [key=other-open]: q\n' > "$home/state/s.status"
run "$CH" repair-inventory s s other-open
echo "=== ADV: answered (closed) call ==="
"$CH" hold closed-call --title c --reason r --repo sample >/dev/null
"$CH" answer closed-call "captain said yes" >/dev/null 2>&1 || (cd "$home" && tasks-axi done closed-call --file "$home/data/backlog.md" >/dev/null 2>&1)
printf 'needs-decision [key=closed-call]: q\n' > "$home/state/c.status"; printf 'decisions_reviewed=1\ndecision_keys=c\n' > "$home/state/c.meta"
run "$CH" repair-inventory c c closed-call; grep decision_keys "$home/state/c.meta"
rm -rf "$T"
