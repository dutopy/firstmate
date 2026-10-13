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
  rc=0; FM_HOME="$home" "$CK" snapshot "$src" --task mine-task >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "an unclaimed slot is not proven and is refused"
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

test_snapshot_contents_and_source_untouched
test_second_pass_is_idempotent_and_deletions_follow
test_shadow_inside_the_worktree_never_snapshots_itself
test_home_private_directories_only_for_the_home_repo
test_deny_change_opens_a_new_lineage
test_ownership_is_proven_before_a_snapshot
test_only_an_explicit_private_answer_publishes
test_visibility_is_proven_fresh_before_every_push
test_no_remote_configured_means_no_publication
test_denied_path_in_a_commit_blocks_the_push
test_a_rejected_push_is_reported_and_never_forced
