#!/usr/bin/env bash
# Behavior tests for bin/fm-wip-checkpoint.sh, run through its executable
# interface against throwaway git repos and a fake gh-axi on PATH.
#
# Snapshot cases prove what the shadow repo contains and that the SOURCE
# repository is left byte-identical (index, refs, objects, HEAD). Ownership
# cases drive the real pool-slot claim. Push cases prove the visibility proof is
# fresh before every push, that only an explicit private answer publishes, that
# a denied path or a rejected push never reaches the remote, and that nothing is
# forced. No case contacts a real forge: the target URL resolves to a local bare
# repo through git's own url.<base>.insteadOf.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

CK="$ROOT/bin/fm-wip-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-wip-checkpoint)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
GIT_GLOBAL="$TMP_ROOT/gitconfig"
: > "$GIT_GLOBAL"
export GIT_CONFIG_GLOBAL="$GIT_GLOBAL" GIT_CONFIG_NOSYSTEM=1
fm_git_identity

# gh-axi fake: prints the visibility in $FAKE_VIS (private|public|fail) and
# counts every call so a test can prove the proof is repeated per push.
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
echo x >> "$FAKE_VIS_CALLS"
case "${FAKE_VIS:-fail}" in
  fail) exit 1 ;;
  *) printf 'repo:\n  name: x\n  visibility: %s\n' "$FAKE_VIS" ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

# Deterministic scanner double reads the actual selected history; the optional
# real-tool run exercises the same publication cases with installed Gitleaks.
REAL_GITLEAKS=$(command -v gitleaks || true)
cat > "$FAKEBIN/gitleaks" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  [ ! -f "$0.wrong-version" ] || { echo 8.29.0; exit 0; }
  echo 8.30.1
  exit 0
fi
if [ -f "$0.fail" ]; then echo 'SYNTHETIC-SECRET-SOURCE-LINE' >&2; exit 2; fi
if [ -f "$0.timeout" ]; then sleep 10; exit 0; fi
[ ! -f "$0.unknown" ] || exit 0
shift
repo=$1; shift
report= opts=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) report=$2; shift 2 ;;
    --log-opts) opts=$2; shift 2 ;;
    --log-opts=*) opts=${1#*=}; shift ;;
    *) shift ;;
  esac
done
if [ -f "$0.mutate" ]; then
  shadow=$repo
  if [ -f "$repo/objects/info/alternates" ]; then
    objects=$(cat "$repo/objects/info/alternates")
    shadow=${objects%/objects}
  fi
  ref=$(git -C "$shadow" for-each-ref --format='%(refname)' | head -n 1)
  before=$(git -C "$shadow" rev-parse "$ref")
  tree=$(git -C "$shadow" rev-parse "$before^{tree}")
  next=$(git -C "$shadow" -c user.name=test -c user.email=test@example.invalid commit-tree "$tree" -p "$before" -m concurrent)
  git -C "$shadow" update-ref "$ref" "$next"
fi
[ -n "$report" ] && [ -n "$opts" ] || exit 2
# Real 8.30.1 always loads this source-side ignore independently of -i.
[ ! -s "$repo/.gitleaksignore" ] || { printf '0\n' > "$report"; exit 0; }
# Only fake test credentials carry this marker, never a real credential.
# Intentional word splitting models the scanner's documented log-opts parsing.
if git -C "$repo" log -p $opts | grep -q 'ghp_k7F9'; then
  printf '1\n' > "$report"
  echo 'SYNTHETIC-SECRET-SOURCE-LINE' >&2
  exit 1
fi
printf '0\n' > "$report"
SH
chmod +x "$FAKEBIN/gitleaks"
if [ "${FM_WIP_TEST_REAL_GITLEAKS:-0}" = 1 ]; then
  [ -n "$REAL_GITLEAKS" ] || fail "real scanner smoke requires installed Gitleaks"
  rm "$FAKEBIN/gitleaks"
  ln -s "$REAL_GITLEAKS" "$FAKEBIN/gitleaks"
fi

# make_src <name>: a source repo with a tracked file, a tracked denied file and
# a mix of untracked, denied, ignored and info/exclude'd files.
make_src() {
  local src="$TMP_ROOT/$1/src"
  mkdir -p "$src"
  git -C "$src" init -q -b main
  printf 'a\n' > "$src/a.txt"
  printf 'tracked-secret\n' > "$src/tracked.pem"
  printf '.artifacts/\n' > "$src/.gitignore"
  git -C "$src" add -A
  git -C "$src" commit -qm base
  printf 'edit\n' >> "$src/a.txt"
  printf 'new\n' > "$src/new.txt"
  printf 'k\n' > "$src/untracked.key"
  printf 'db\n' > "$src/x.sqlite3"
  local n
  for n in app.db app.db-wal app.db-shm app.sqlite app.sqlite-wal app.sqlite3-shm .npmrc .git-credentials auth.p8 store.jks UPPER.PEM Id_RSA .ENV; do
    printf 'secret\n' > "$src/$n"
  done
  mkdir -p "$src/.artifacts" "$src/corpus" "$src/config"
  printf 'big\n' > "$src/.artifacts/blob"
  printf 'c\n' > "$src/corpus/c.txt"
  printf 'cfg\n' > "$src/config/app.toml"
  printf 'private\n' > "$src/info-ignored.txt"
  printf 'info-ignored.txt\n' >> "$src/.git/info/exclude"
  printf '%s\n' "$src"
}

make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

shadow_of() {  # <home> -> shadow git dir
  local d
  d=$(find "$1/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  printf '%s\n' "$d"
}

source_fingerprint() {  # <src>
  printf '%s %s %s %s\n' \
    "$(shasum "$1/.git/index" | awk '{print $1}')" \
    "$(git -C "$1" for-each-ref | shasum | awk '{print $1}')" \
    "$(find "$1/.git/objects" -type f | wc -l | tr -d ' ')" \
    "$(git -C "$1" rev-parse HEAD)"
}

test_snapshot_contents_and_source_untouched() {
  local src home before after shadow ref files
  src=$(make_src snap); home=$(make_home snap)
  before=$(source_fingerprint "$src")
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null || fail "snapshot must succeed"
  after=$(source_fingerprint "$src")
  assert_equals "$before" "$after" "the source index, refs, objects and HEAD are unchanged"
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  files=$(git --git-dir="$shadow" ls-tree -r --name-only "$ref" | tr '\n' ' ')
  assert_equals ".gitignore a.txt config/app.toml new.txt " "$files" "only eligible files are captured"
  assert_not_contains "$files" "tracked.pem" "a tracked denied file is excluded"
  assert_not_contains "$files" "info-ignored" "a source .git/info/exclude rule is honoured"
  assert_not_contains "$files" "corpus" "the corpus directory is excluded"
  if git --git-dir="$shadow" cat-file -e "$(git -C "$src" rev-parse HEAD)" 2>/dev/null; then
    fail "the shadow repo must not reach the source ancestry"
  fi
  pass "fm-wip-checkpoint: snapshot is filtered, orphan, and leaves the source untouched"
}

test_second_pass_is_idempotent_and_deletions_follow() {
  local src home out shadow ref
  src=$(make_src idem); home=$(make_home idem)
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  out=$(FM_HOME="$home" "$CK" snapshot "$src")
  assert_contains "$out" "unchanged" "an identical tree creates no second commit"
  rm "$src/new.txt"
  out=$(FM_HOME="$home" "$CK" snapshot "$src")
  assert_contains "$out" "checkpoint" "a deletion is a change"
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  assert_not_contains "$(git --git-dir="$shadow" ls-tree -r --name-only "$ref")" "new.txt" "the deleted file leaves the shadow tree"
  pass "fm-wip-checkpoint: idempotent snapshot, deletions tracked"
}

test_shadow_inside_the_worktree_never_snapshots_itself() {
  local src home out shadow ref
  src=$(make_src selfx); home="$src/state-home"
  mkdir -p "$home/state" "$home/config"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null || fail "snapshot with an in-tree shadow must succeed"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  out=$(git --git-dir="$shadow" ls-tree -r --name-only "$ref")
  assert_not_contains "$out" "state-home/state/wip" "the shadow store is never captured"
  pass "fm-wip-checkpoint: an in-tree shadow store excludes itself"
}

test_home_private_directories_only_for_the_home_repo() {
  local home out shadow ref
  home=$(make_home homerepo)
  git -C "$home" init -q -b main
  printf 'x\n' > "$home/AGENTS.md"
  mkdir -p "$home/data" "$home/projects" "$home/config"
  printf 'p\n' > "$home/data/private.md"
  printf 'p\n' > "$home/projects/p.txt"
  printf 'p\n' > "$home/config/c"
  git -C "$home" add AGENTS.md
  git -C "$home" commit -qm init
  FM_HOME="$home" "$CK" snapshot "$home" >/dev/null || fail "home snapshot must succeed"
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  out=$(git --git-dir="$shadow" ls-tree -r --name-only "$ref" | tr '\n' ' ')
  assert_equals "AGENTS.md " "$out" "the home repository never captures data, state, config or projects"
  pass "fm-wip-checkpoint: home-private directories are denied only in the home's own repository"
}

test_deny_change_opens_a_new_lineage() {
  local src home out
  src=$(make_src lineage); home=$(make_home lineage)
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  printf '**/extra-private/**\n' > "$home/config/wip-exclude"
  printf 'x\n' >> "$src/a.txt"
  out=$(FM_HOME="$home" "$CK" snapshot "$src")
  assert_contains "$out" "/e2 " "a changed deny list starts lineage e2"
  pass "fm-wip-checkpoint: a deny-list change opens a new lineage"
}

# claim_slot <pool-slot-parent> <task>: write a pool slot owner claim.
claim_slot() {
  printf 'task=%s\nhome=%s\n' "$2" "$TMP_ROOT" > "$1/.fm-slot-owner"
}

test_ownership_is_proven_before_a_snapshot() {
  local pool src home rc=0
  pool="$TMP_ROOT/own/pool/1"; mkdir -p "$pool"
  src="$pool/repo"; mkdir -p "$src"
  git -C "$src" init -q -b main; printf 'a\n' > "$src/a.txt"; git -C "$src" add -A; git -C "$src" commit -qm i
  home=$(make_home own)
  claim_slot "$pool" other-task
  FM_HOME="$home" "$CK" snapshot "$src" --task mine-task >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "a slot claimed by another task is refused"
  assert_absent "$home/state/wip" "a refused snapshot creates no WIP state"
  rm -f "$pool/.fm-slot-owner"
  : > "$TMP_ROOT/own/pool/treehouse-state.json"
  rc=0; FM_HOME="$home" "$CK" snapshot "$src" --task mine-task >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unclaimed Treehouse slot is not proven and is refused"
  claim_slot "$pool" mine-task
  rc=0; FM_HOME="$home" "$CK" snapshot "$src" --task mine-task >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a slot claimed by this task is snapshotted"
  printf 'garbage' > "$pool/.fm-slot-owner"
  rc=0; FM_HOME="$home" "$CK" snapshot "$src" --task mine-task >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unreadable claim is refused"
  pass "fm-wip-checkpoint: snapshots happen only for a freshly proven slot owner"
}

# push fixtures: a bare "GitHub" repo behind url.<base>.insteadOf.
setup_push() {  # <name> -> prints "<src> <home> <remote>"
  local src home remote
  src=$(make_src "$1"); home=$(make_home "$1")
  remote="$TMP_ROOT/$1/remote.git"
  git init -q --bare "$remote"
  : > "$GIT_GLOBAL"
  git config --file "$GIT_GLOBAL" "url.$remote.insteadOf" "https://github.com/acme/wip.git"
  printf 'proj acme/wip\n' > "$home/config/wip-remotes"
  FM_HOME="$home" "$CK" snapshot "$src" --milestone >/dev/null
  printf '%s %s %s\n' "$src" "$home" "$remote"
}

run_push() {  # <home> <src> <vis>
  env FM_HOME="$1" FM_VIS="$3" FAKE_VIS="$3" FAKE_VIS_CALLS="$TMP_ROOT/calls" PATH="$FAKEBIN:$PATH" \
    "$CK" push "$2" --project proj
}

test_only_an_explicit_private_answer_publishes() {
  local src home remote rc
  read -r src home remote < <(setup_push pushvis)
  for vis in public fail; do
    rc=0; run_push "$home" "$src" "$vis" >/dev/null 2>&1 || rc=$?
    expect_code 5 "$rc" "visibility '$vis' must refuse publication"
    [ -z "$(git --git-dir="$remote" for-each-ref)" ] || fail "nothing may reach the remote when visibility is '$vis'"
  done
  rc=0; run_push "$home" "$src" private >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "an explicit private answer publishes"
  assert_contains "$(git --git-dir="$remote" for-each-ref --format='%(refname)')" "refs/heads/wip/" "the WIP ref reached the remote"
  assert_contains "$(cat "$(find "$home/state/wip" -name push | head -n 1)")" "result=pushed" "a durable push receipt is written"
  pass "fm-wip-checkpoint: only an explicit private answer publishes, receipt on success"
}

test_visibility_is_proven_fresh_before_every_push() {
  local src home remote before after rc=0
  read -r src home remote < <(setup_push fresh)
  : > "$TMP_ROOT/calls"
  run_push "$home" "$src" private >/dev/null 2>&1
  run_push "$home" "$src" private >/dev/null 2>&1
  before=$(wc -l < "$TMP_ROOT/calls" | tr -d ' ')
  assert_equals 2 "$before" "two pushes ask the forge twice, no cache"
  # repository turns public between two pushes
  printf 'more\n' >> "$src/a.txt"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  rc=0; run_push "$home" "$src" public >/dev/null 2>&1 || rc=$?
  expect_code 5 "$rc" "a repository that became public blocks the next push"
  after=$(git --git-dir="$remote" rev-parse "$(git --git-dir="$remote" for-each-ref --format='%(refname)' | head -n 1)")
  assert_not_equals "$(git --git-dir="$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)" rev-parse "$(git --git-dir="$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)" for-each-ref --format='%(refname)' | head -n 1)")" "$after" "the new checkpoint was not published"
  pass "fm-wip-checkpoint: visibility is proven fresh before every push"
}

test_no_remote_configured_means_no_publication() {
  local src home remote rc=0
  read -r src home remote < <(setup_push noremote)
  : > "$home/config/wip-remotes"
  run_push "$home" "$src" private >/dev/null 2>&1 || rc=$?
  expect_code 4 "$rc" "no configured remote is exit 4"
  [ -z "$(git --git-dir="$remote" for-each-ref)" ] || fail "nothing is published without a configured remote"
  pass "fm-wip-checkpoint: no configured remote means no publication"
}

test_publication_can_be_declared_off_for_a_project() {
  local src home remote rc=0
  read -r src home remote < <(setup_push puboff)
  printf 'proj none\n' > "$home/config/wip-remotes"
  : > "$TMP_ROOT/calls"
  run_push "$home" "$src" private >/dev/null 2>&1 || rc=$?
  expect_code 8 "$rc" "a project declared 'none' is intentionally unpublished"
  assert_equals 0 "$(wc -l < "$TMP_ROOT/calls" | tr -d ' ')" "no forge call is made for an unpublished project"
  [ -z "$(git --git-dir="$remote" for-each-ref)" ] || fail "nothing may be published for a project declared none"
  assert_contains "$(cat "$(find "$home/state/wip" -name push | head -n 1)")" "result=off" "the posture is recorded as off, not as a fault"
  pass "fm-wip-checkpoint: publication declared off is a posture, not a failure"
}

test_denied_path_in_a_commit_blocks_the_push() {
  local src home remote shadow ref tree commit blob rc=0
  read -r src home remote < <(setup_push denyhit)
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  # forge a shadow commit that names a denied (empty) file
  blob=$(git --git-dir="$shadow" hash-object -w --stdin < /dev/null)
  rm -f "$TMP_ROOT/forge.idx"
  GIT_INDEX_FILE="$TMP_ROOT/forge.idx" git --git-dir="$shadow" read-tree "$ref"
  GIT_INDEX_FILE="$TMP_ROOT/forge.idx" git --git-dir="$shadow" update-index --add --cacheinfo "100644,$blob,leak.pem"
  tree=$(GIT_INDEX_FILE="$TMP_ROOT/forge.idx" git --git-dir="$shadow" write-tree)
  commit=$(git --git-dir="$shadow" commit-tree "$tree" -p "$ref" -m forged)
  git --git-dir="$shadow" update-ref "$ref" "$commit"
  run_push "$home" "$src" private >/dev/null 2>&1 || rc=$?
  expect_code 6 "$rc" "a denied path in the publish range blocks the push"
  [ -z "$(git --git-dir="$remote" for-each-ref)" ] || fail "no denied history may reach the remote"
  pass "fm-wip-checkpoint: the publish range is re-checked against the deny list"
}

test_home_private_paths_in_a_commit_block_the_push() {
  local home remote shadow ref tree commit blob d rc=0
  home=$(make_home homeleak); remote="$TMP_ROOT/homeleak/remote.git"
  git init -q --bare "$remote"
  : > "$GIT_GLOBAL"
  git config --file "$GIT_GLOBAL" "url.$remote.insteadOf" "https://github.com/acme/wip.git"
  printf 'proj acme/wip\n' > "$home/config/wip-remotes"
  git -C "$home" init -q -b main
  printf 'x\n' > "$home/AGENTS.md"
  git -C "$home" add AGENTS.md; git -C "$home" commit -qm init
  FM_HOME="$home" "$CK" snapshot "$home" --milestone >/dev/null || fail "home snapshot must succeed"
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  # forge a shadow commit that carries a home-private directory
  blob=$(printf 'secret\n' | git --git-dir="$shadow" hash-object -w --stdin)
  rm -f "$TMP_ROOT/forge.idx"
  GIT_INDEX_FILE="$TMP_ROOT/forge.idx" git --git-dir="$shadow" read-tree "$ref"
  for d in data state config projects .no-mistakes; do
    GIT_INDEX_FILE="$TMP_ROOT/forge.idx" git --git-dir="$shadow" update-index --add --cacheinfo "100644,$blob,$d/leak.txt"
  done
  tree=$(GIT_INDEX_FILE="$TMP_ROOT/forge.idx" git --git-dir="$shadow" write-tree)
  commit=$(git --git-dir="$shadow" commit-tree "$tree" -p "$ref" -m forged)
  git --git-dir="$shadow" update-ref "$ref" "$commit"
  run_push "$home" "$home" private >/dev/null 2>&1 || rc=$?
  expect_code 6 "$rc" "a home-private path in the publish range blocks the push"
  [ -z "$(git --git-dir="$remote" for-each-ref)" ] || fail "no home-private history may reach the remote"
  pass "fm-wip-checkpoint: the publish range is re-checked against the home-private directories"
}

test_a_rejected_push_is_reported_and_never_forced() {
  local src home remote shadow ref other rc=0 before
  read -r src home remote < <(setup_push reject)
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  # the remote already holds a divergent commit on the same ref
  other=$(git --git-dir="$remote" commit-tree "$(git --git-dir="$remote" hash-object -t tree /dev/null)" -m divergent)
  git --git-dir="$remote" update-ref "$ref" "$other"
  before=$(git --git-dir="$remote" rev-parse "$ref")
  run_push "$home" "$src" private >/dev/null 2>&1 || rc=$?
  expect_code 7 "$rc" "a non-fast-forward push fails"
  assert_equals "$before" "$(git --git-dir="$remote" rev-parse "$ref")" "the remote ref is untouched: never forced"
  pass "fm-wip-checkpoint: a rejected push is reported and never forced"
}

# A7: one unreadable file must not fail the whole snapshot.
test_an_unreadable_file_does_not_fail_the_snapshot() {
  local src home shadow ref files
  [ "$(id -u)" != 0 ] || { pass "fm-wip-checkpoint: unreadable file case skipped as root"; return 0; }
  src=$(make_src unreadable); home=$(make_home unreadable)
  printf 'secret-ish\n' > "$src/unreadable.txt"
  chmod 000 "$src/unreadable.txt"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null || fail "an unreadable file must not fail the snapshot"
  chmod 600 "$src/unreadable.txt"
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  files=$(git --git-dir="$shadow" ls-tree -r --name-only "$ref" | tr '\n' ' ')
  assert_contains "$files" "a.txt" "readable files are still captured"
  assert_not_contains "$files" "unreadable.txt" "the unreadable file is skipped"
  assert_contains "$(cat "$(find "$home/state/wip" -name ckpt | head -n 1)")" "best_effort=1" "the checkpoint is marked best effort"
  pass "fm-wip-checkpoint: an unreadable file is skipped, the snapshot still lands (best effort)"
}

# A8/F11: the size cap holds for odd names (leading dash, literal 'total'); special files do not hang.
test_the_size_cap_holds_for_odd_names_and_special_files_do_not_hang() {
  local src home shadow ref files rc=0
  src=$(make_src oddnames); home=$(make_home oddnames)
  dd if=/dev/zero of="$src/-huge.bin" bs=1048576 count=0 seek=95 2>/dev/null
  dd if=/dev/zero of="$src/total" bs=1048576 count=0 seek=95 2>/dev/null
  printf 'small\n' > "$src/small.txt"
  mkfifo "$src/pipe"
  ln -s pipe "$src/pipelink"
  fm_run_timed 40 env FM_HOME="$home" "$CK" snapshot "$src" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the snapshot finishes (a FIFO behind a symlink must not hang it)"
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  files=$(git --git-dir="$shadow" ls-tree -r --name-only "$ref" | tr '\n' ' ')
  assert_not_contains "$files" "-huge.bin" "a file named with a leading dash is still size-capped"
  assert_not_contains "$files" "total" "a file literally named total is still size-capped"
  assert_contains "$files" "small.txt" "ordinary files are captured"
  pass "fm-wip-checkpoint: the size cap holds for odd names and special files do not hang"
}

# A9: behavior parity at a larger scale (deletions follow, everything present is captured).
test_a_large_tree_snapshots_with_deletions_following() {
  local src home shadow ref d f count
  src=$(make_src large); home=$(make_home large)
  for d in $(seq 1 20); do
    mkdir -p "$src/bulk$d"
    for f in $(seq 1 150); do printf '%s\n' "$f" > "$src/bulk$d/f$f.txt"; done
  done
  fm_run_timed 120 env FM_HOME="$home" "$CK" snapshot "$src" >/dev/null || fail "a 3000-file tree must snapshot within the bound"
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  count=$(git --git-dir="$shadow" ls-tree -r --name-only "$ref" | grep -c '^bulk')
  assert_equals 3000 "$count" "every present file is captured"
  rm "$src/bulk1/f1.txt"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  assert_equals 2999 "$(git --git-dir="$shadow" ls-tree -r --name-only "$ref" | grep -c '^bulk')" "a deleted file leaves the tree"
  pass "fm-wip-checkpoint: a large tree snapshots with deletions following"
}

# C11: a slow push is its own result (timeout), not a rejection, and the bound is separate from the visibility read.
test_a_slow_push_is_reported_as_a_timeout_not_a_rejection() {
  local src home remote rc=0
  read -r src home remote < <(setup_push pushtimeout)
  printf '#!/bin/sh\nsleep 6\nexit 0\n' > "$remote/hooks/pre-receive"
  chmod +x "$remote/hooks/pre-receive"
  env FM_HOME="$home" FAKE_VIS=private FAKE_VIS_CALLS="$TMP_ROOT/calls" PATH="$FAKEBIN:$PATH" FM_WIP_PUSH_TIMEOUT=1 \
    "$CK" push "$src" --project proj >/dev/null 2>&1 || rc=$?
  expect_code 7 "$rc" "a push that outlives its bound fails"
  assert_contains "$(cat "$(find "$home/state/wip" -name push | head -n 1)")" "result=push-timeout" "a timeout is recorded as its own result"
  pass "fm-wip-checkpoint: a slow push is a timeout result, not a rejection"
}

# B3: when the push-time recognition of the home repository cannot be settled, the push is refused before any forge call.
test_an_undeterminable_home_state_refuses_the_push_without_a_forge_call() {
  local src home remote real rc=0
  read -r src home remote < <(setup_push undeterminable)
  real=$(command -v git)
  mkdir -p "$TMP_ROOT/slowgit"
  printf '#!/bin/sh\ncase "$*" in *--git-common-dir*) sleep 5 ;; esac\nexec %s "$@"\n' "$real" > "$TMP_ROOT/slowgit/git"
  chmod +x "$TMP_ROOT/slowgit/git"
  : > "$TMP_ROOT/calls"
  env FM_HOME="$home" FAKE_VIS=private FAKE_VIS_CALLS="$TMP_ROOT/calls" PATH="$TMP_ROOT/slowgit:$FAKEBIN:$PATH" FM_WIP_GIT_TIMEOUT=1 \
    "$CK" push "$src" --project proj >/dev/null 2>&1 || rc=$?
  expect_code 6 "$rc" "an undeterminable home recognition refuses the push"
  assert_equals 0 "$(wc -l < "$TMP_ROOT/calls" | tr -d ' ')" "no forge call is made before the local refusal"
  [ -z "$(git --git-dir="$remote" for-each-ref)" ] || fail "nothing may reach the remote"
  pass "fm-wip-checkpoint: an undeterminable home recognition refuses the push before any forge call"
}

# Removing the content guard, scanning only the tip tree, or trusting a receipt
# would all publish the synthetic secret in these cases.
test_content_in_current_and_deleted_history_blocks_publication() {
  local src home remote before out rc shadow ref commit
  read -r src home remote < <(setup_push content)
  run_push "$home" "$src" private >/dev/null 2>&1 || fail "clean history must publish"
  before=$(git --git-dir="$remote" for-each-ref)
  # Deliberately synthetic, unissued credential; split so this test source is not
  # itself a credential fixture in the repository's own content scan.
  printf 'github_token = "ghp_%s" # gitleaks:allow\n' 'k7F9bQ2mX4rT8vW1nY5pL3sA6dE0cH9jK2uZ' > "$src/settings.txt"
  printf '[allowlist]\npaths = [".*"]\n' > "$src/.gitleaks.toml"
  printf '[allowlist]\npaths = [".*"]\n' > "$home/untrusted.toml"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null || fail "synthetic checkpoint must exist"
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  commit=$(git --git-dir="$shadow" rev-parse "$ref")
  printf '%s:settings.txt:github-pat:1\n' "$commit" > "$src/.gitleaksignore"
  cp "$src/.gitleaks.toml" "$shadow/.gitleaks.toml"
  cp "$src/.gitleaksignore" "$shadow/.gitleaksignore"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  rc=0
  out=$(GITLEAKS_CONFIG="$home/untrusted.toml" GITLEAKS_CONFIG_TOML="$(cat "$home/untrusted.toml")" \
    GITLEAKS_ENABLE_RULE=nonexistent run_push "$home" "$src" private 2>&1) || rc=$?
  expect_code 9 "$rc" "a content finding refuses publication despite repository and ambient suppressions"
  assert_equals "$before" "$(git --git-dir="$remote" for-each-ref)" "a finding leaves all remote refs unchanged"
  assert_not_contains "$out" "k7F9" "no synthetic secret value appears in diagnostics"
  assert_not_contains "$out" "SYNTHETIC-SECRET-SOURCE-LINE" "scanner error output is never relayed"
  rm "$src/settings.txt"
  FM_HOME="$home" "$CK" snapshot "$src" >/dev/null
  # A forged or old receipt must not shrink the content scan.
  printf 'pushed_commit=%s\n' "$(git --git-dir="$shadow" rev-parse "$ref")" > "$(dirname "$shadow")/$(basename "$shadow" .git)/push"
  rc=0; out=$(run_push "$home" "$src" private 2>&1) || rc=$?
  expect_code 9 "$rc" "a secret introduced then deleted is still refused"
  assert_equals "$before" "$(git --git-dir="$remote" for-each-ref)" "deleted secret history never reaches the remote"
  pass "fm-wip-checkpoint: current and deleted synthetic secrets block publication without values"
}

test_merge_and_binary_content_cannot_hide_deleted_secrets() {
  local kind src home remote shadow ref base left right blob tree merged tip rc before
  for kind in merge binary; do
    read -r src home remote < <(setup_push "$kind")
    shadow=$(shadow_of "$home")
    ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
    base=$(git --git-dir="$shadow" rev-parse "$ref")
    before=$(git --git-dir="$remote" for-each-ref)
    tree=$(git --git-dir="$shadow" rev-parse "$base^{tree}")
    left=$(git --git-dir="$shadow" commit-tree "$tree" -p "$base" -m left)
    right=$(git --git-dir="$shadow" commit-tree "$tree" -p "$base" -m right)
    blob=$({
      [ "$kind" != binary ] || printf '\0'
      printf 'github_token = "ghp_%s"\n' 'k7F9bQ2mX4rT8vW1nY5pL3sA6dE0cH9jK2uZ'
    } | git --git-dir="$shadow" hash-object -w --stdin)
    GIT_INDEX_FILE="$TMP_ROOT/content.idx" git --git-dir="$shadow" read-tree "$base"
    GIT_INDEX_FILE="$TMP_ROOT/content.idx" git --git-dir="$shadow" update-index --add --cacheinfo "100644,$blob,settings.txt"
    tree=$(GIT_INDEX_FILE="$TMP_ROOT/content.idx" git --git-dir="$shadow" write-tree)
    if [ "$kind" = merge ]; then
      merged=$(git --git-dir="$shadow" commit-tree "$tree" -p "$left" -p "$right" -m merge-only-secret)
    else
      merged=$(git --git-dir="$shadow" commit-tree "$tree" -p "$base" -m binary-secret)
    fi
    tip=$(git --git-dir="$shadow" commit-tree "$(git --git-dir="$shadow" rev-parse "$base^{tree}")" -p "$merged" -m removed)
    git --git-dir="$shadow" update-ref "$ref" "$tip"
    rc=0; run_push "$home" "$src" private >/dev/null 2>&1 || rc=$?
    expect_code 9 "$rc" "$kind content introduced then deleted must refuse publication"
    assert_equals "$before" "$(git --git-dir="$remote" for-each-ref)" "$kind secret never reaches remote refs"
  done
  pass "fm-wip-checkpoint: merge-only and binary deleted secrets cannot bypass the scan"
}

test_scanner_failure_and_unknown_results_refuse_publication() {
  local src home remote mode rc out before
  [ "${FM_WIP_TEST_REAL_GITLEAKS:-0}" != 1 ] || return 0
  read -r src home remote < <(setup_push scanerrors)
  before=$(git --git-dir="$remote" for-each-ref)
  for mode in fail timeout unknown wrong-version; do
    : > "$FAKEBIN/gitleaks.$mode"
    rc=0
    out=$(FM_WIP_SCAN_TIMEOUT=1 run_push "$home" "$src" private 2>&1) || rc=$?
    rm "$FAKEBIN/gitleaks.$mode"
    expect_code 9 "$rc" "scanner $mode must refuse publication"
    assert_equals "$before" "$(git --git-dir="$remote" for-each-ref)" "scanner $mode leaves remote refs unchanged"
    assert_not_contains "$out" "SYNTHETIC-SECRET-SOURCE-LINE" "scanner errors do not expose source text"
  done
  # An unavailable executable must refuse even on hosts with real Gitleaks.
  mv "$FAKEBIN/gitleaks" "$FAKEBIN/scanner.saved"
  ln -s "$TMP_ROOT/absent-scanner" "$FAKEBIN/gitleaks"
  rc=0
  out=$(PATH="$FAKEBIN:/usr/bin:/bin" run_push "$home" "$src" private 2>&1) || rc=$?
  rm "$FAKEBIN/gitleaks"
  mv "$FAKEBIN/scanner.saved" "$FAKEBIN/gitleaks"
  expect_code 9 "$rc" "missing scanner must refuse publication"
  assert_equals "$before" "$(git --git-dir="$remote" for-each-ref)" "missing scanner leaves remote unchanged"
  pass "fm-wip-checkpoint: unavailable, failed, timed-out and unknown scans refuse publication"
}

test_push_uses_the_scanned_commit_even_if_the_ref_moves() {
  local src home remote shadow ref expected receipt
  [ "${FM_WIP_TEST_REAL_GITLEAKS:-0}" != 1 ] || return 0
  read -r src home remote < <(setup_push immutable)
  shadow=$(shadow_of "$home")
  ref=$(git --git-dir="$shadow" for-each-ref --format='%(refname)' | head -n 1)
  expected=$(git --git-dir="$shadow" rev-parse "$ref")
  : > "$FAKEBIN/gitleaks.mutate"
  run_push "$home" "$src" private >/dev/null 2>&1 || fail "scanned clean commit can publish"
  rm "$FAKEBIN/gitleaks.mutate"
  assert_not_equals "$expected" "$(git --git-dir="$shadow" rev-parse "$ref")" "fixture moved the mutable ref during scanning"
  assert_equals "$expected" "$(git --git-dir="$remote" rev-parse "$ref")" "only the immutable scanned commit was published"
  receipt=$(cat "$(find "$home/state/wip" -name push | head -n 1)")
  assert_contains "$receipt" "pushed_commit=$expected" "the receipt names the scanned commit"
  pass "fm-wip-checkpoint: scan, push and receipt bind the same immutable commit"
}

test_content_in_current_and_deleted_history_blocks_publication
test_merge_and_binary_content_cannot_hide_deleted_secrets
test_scanner_failure_and_unknown_results_refuse_publication
test_push_uses_the_scanned_commit_even_if_the_ref_moves

test_snapshot_contents_and_source_untouched
test_second_pass_is_idempotent_and_deletions_follow
test_shadow_inside_the_worktree_never_snapshots_itself
test_home_private_directories_only_for_the_home_repo
test_deny_change_opens_a_new_lineage
test_ownership_is_proven_before_a_snapshot
test_only_an_explicit_private_answer_publishes
test_visibility_is_proven_fresh_before_every_push
test_no_remote_configured_means_no_publication
test_publication_can_be_declared_off_for_a_project
test_denied_path_in_a_commit_blocks_the_push
test_home_private_paths_in_a_commit_block_the_push
test_a_rejected_push_is_reported_and_never_forced

test_an_unreadable_file_does_not_fail_the_snapshot
test_the_size_cap_holds_for_odd_names_and_special_files_do_not_hang
test_a_large_tree_snapshots_with_deletions_following
test_a_slow_push_is_reported_as_a_timeout_not_a_rejection
test_an_undeterminable_home_state_refuses_the_push_without_a_forge_call
