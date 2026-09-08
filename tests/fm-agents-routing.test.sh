#!/usr/bin/env bash
# Behavior tests for the repository agent-instruction routing contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOC="$ROOT/docs/agents-routing.md"
TMP_ROOT=$(fm_test_tmproot fm-agents-routing)

assert_inventory() {
  local count
  count=$(awk 'BEGIN { in_table=0; count=0 }
    /^\| Surface \| Role \|$/ { in_table=1; next }
    in_table && /^\| ---/ { next }
    in_table && /^\|/ { count++; next }
    in_table && !/^\|/ { exit }
    END { print count }' "$DOC")
  [ "$count" -eq 14 ] || fail "routing inventory contains $count surfaces, expected 14"
  for path in \
    AGENTS.md CLAUDE.md CONTRIBUTING.md README.md docs/architecture.md \
    docs/configuration.md docs/scripts.md docs/secondmate-parent-channel.md \
    docs/sessionstart-nudge.md docs/subagent-guard.md \
    docs/supervision-protocols/grok.md docs/supervision-protocols/unknown.md \
    docs/turnend-guard.md; do
    assert_grep "| \`$path\` |" "$DOC" "routing inventory omitted $path"
    assert_present "$ROOT/$path" "$path is missing"
  done
}

assert_independent_public_memory_surfaces() {
  local path discovered=0
  if grep -Fq "| \`docs/cd-guard.md\` |" "$DOC"; then
    fail "mechanics-only docs/cd-guard.md must remain outside the routing inventory"
  fi
  while IFS= read -r path; do
    discovered=$((discovered + 1))
    [ "$path" != "docs/cd-guard.md" ] || \
      fail "mechanics-only docs/cd-guard.md was independently classified as a routing surface"
    assert_present "$ROOT/$path" "$path is missing"
    assert_grep "| \`$path\` |" "$DOC" \
      "routing inventory omitted independently discovered public memory surface $path"
  done < <(
    while IFS= read -r path; do
      if grep -Fq 'project-level memory file' "$ROOT/$path" && \
         grep -Fq 'CLAUDE.md' "$ROOT/$path" && grep -Fq 'AGENTS.md' "$ROOT/$path"; then
        printf '%s\n' "$path"
      fi
    done < <(git -C "$ROOT" ls-files '*.md' '*.mdx' '*.rst' '*.txt')
  )
  [ "$discovered" -gt 0 ] || fail "independent public memory-surface probe found no qualifying files"
}

test_inventory_and_canonical_pointer() {
  local fixture
  assert_present "$DOC" "routing inventory is missing"
  assert_inventory
  assert_independent_public_memory_surfaces
  [ ! -L "$ROOT/CLAUDE.md" ] || fail "root CLAUDE.md must be a regular pointer file"
  fixture="$TMP_ROOT/pointer-owner"
  mkdir -p "$fixture"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$fixture" >/dev/null 2>&1 || \
    fail "public migration helper could not create a pointer fixture"
  cmp -s "$ROOT/CLAUDE.md" "$fixture/CLAUDE.md" || \
    fail "root CLAUDE.md disagrees with the public migration owner"
  [ -L "$ROOT/.claude/skills" ] || fail ".claude/skills must remain a symlink"
  [ "$(readlink "$ROOT/.claude/skills")" = "../.agents/skills" ] || \
    fail ".claude/skills points at the wrong skill tree"
  pass "fm-agents-routing: inventory and canonical pointer are valid"
}

test_discoverability_and_owner_language() {
  local count
  assert_grep 'docs/agents-routing.md' "$ROOT/README.md" \
    "README does not make the routing inventory discoverable"
  assert_grep 'agents-routing.md' "$ROOT/docs/architecture.md" \
    "architecture docs do not point at the routing inventory"
  assert_grep 'sole canonical supervisor contract' "$DOC" \
    "inventory does not name AGENTS.md as the canonical owner"
  assert_grep 'bin/fm-ensure-agents-md.sh' "$DOC" \
    "inventory does not identify the migration owner"
  for source in "$ROOT/README.md" "$ROOT/CONTRIBUTING.md" "$ROOT/docs/architecture.md"; do
    count=$(grep -F -c 'agents-routing.md' "$source")
    [ "$count" -eq 1 ] || fail "${source#"$ROOT/"} has $count routing-inventory pointers, expected one"
  done
  assert_grep 'firstmate-coding-guidelines' "$ROOT/AGENTS.md" \
    "always-loaded contract lost the shared-material skill trigger"
  assert_grep 'docs/sessionstart-nudge.md' "$ROOT/AGENTS.md" \
    "always-loaded contract lost the native session-start route"
  assert_grep 'docs/turnend-guard.md' "$ROOT/AGENTS.md" \
    "always-loaded contract lost the turn-end backstop route"
  assert_grep 'docs/secondmate-parent-channel.md' "$ROOT/AGENTS.md" \
    "always-loaded contract lost the secondmate parent-channel route"
  pass "fm-agents-routing: canonical ownership and migration remain discoverable"
}

test_inventory_and_canonical_pointer
test_discoverability_and_owner_language
