#!/usr/bin/env bash
# Live driver for the memory-helper / worker-guard scenarios.
# Runs the REAL bin/fm-ensure-agents-md.sh and the REAL
# bin/fm-worker-guard-pretool-check.sh transport against disposable projects.
set -u
ROOT=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
HELPER="$ROOT/bin/fm-ensure-agents-md.sh"
CHECK="$ROOT/bin/fm-worker-guard-pretool-check.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-mem-scen.XXXXXX")
FOREIGN="$TMP/foreign"
mkdir -p "$FOREIGN/keep"
printf 'precious\n' >"$FOREIGN/keep/data"

fails=0
say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- live helper runs
run_kind() {
  kind=$1
  repo="$TMP/repo-$kind"
  mkdir -p "$repo"
  case "$kind" in
    governed | owned-link | foreign-link | real-conflict)
      printf '<!-- firstmate:maintained-by-project -->\n# Project memory\n\nRetain our project-specific maintenance guidance.\n' >"$repo/AGENTS.md"
      cp "$repo/AGENTS.md" "$repo/before"
      ;;
  esac
  case "$kind" in
    owned-link) ln -s AGENTS.md "$repo/CLAUDE.md" ;;
    foreign-link) ln -s "$FOREIGN/keep/data" "$repo/CLAUDE.md" ;;
    agents-link) ln -s "$FOREIGN/keep/data" "$repo/AGENTS.md" ;;
    real-conflict) printf 'Distinct project instructions.\n' >"$repo/CLAUDE.md" ;;
  esac

  say "=== helper live run: $kind ==="
  out=$(cd "$repo" && "$HELPER" . 2>&1); code=$?
  say "exit=$code"
  say "output: $out"

  case "$kind" in
    fresh | governed | owned-link)
      [ "$code" -eq 0 ] || { say "FAIL $kind exit"; fails=$((fails+1)); }
      [ -f "$repo/AGENTS.md" ] && [ ! -L "$repo/AGENTS.md" ] || { say "FAIL $kind AGENTS real file"; fails=$((fails+1)); }
      [ -f "$repo/CLAUDE.md" ] && [ ! -L "$repo/CLAUDE.md" ] || { say "FAIL $kind CLAUDE real file"; fails=$((fails+1)); }
      cmp -s "$repo/CLAUDE.md" - <<'EOF' || { say "FAIL $kind pointer content"; fails=$((fails+1)); }
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
      if [ -f "$repo/before" ]; then
        # The project-owned first-line mark declares retained guidance, so the
        # helper must leave AGENTS.md byte-identical and add no section.
        cmp -s "$repo/before" "$repo/AGENTS.md" || { say "FAIL $kind governance altered"; fails=$((fails+1)); }
      else
        grep -Fq '## Maintaining this file' "$repo/AGENTS.md" || { say "FAIL $kind no maintenance section"; fails=$((fails+1)); }
      fi
      # idempotent rerun
      cp "$repo/AGENTS.md" "$repo/a1"; cp "$repo/CLAUDE.md" "$repo/c1"
      (cd "$repo" && "$HELPER" .) >/dev/null 2>&1 || { say "FAIL $kind rerun exit"; fails=$((fails+1)); }
      cmp -s "$repo/a1" "$repo/AGENTS.md" || { say "FAIL $kind rerun changed AGENTS"; fails=$((fails+1)); }
      cmp -s "$repo/c1" "$repo/CLAUDE.md" || { say "FAIL $kind rerun changed CLAUDE"; fails=$((fails+1)); }
      say "OK $kind"
      ;;
    foreign-link)
      [ "$code" -ne 0 ] || { say "FAIL foreign-link allowed"; fails=$((fails+1)); }
      [ -L "$repo/CLAUDE.md" ] || { say "FAIL foreign-link removed"; fails=$((fails+1)); }
      [ "$(cat "$FOREIGN/keep/data")" = precious ] || { say "FAIL foreign-link clobbered"; fails=$((fails+1)); }
      say "OK foreign-link refused, foreign link + data preserved"
      ;;
    agents-link)
      [ "$code" -ne 0 ] || { say "FAIL agents-link allowed"; fails=$((fails+1)); }
      [ -L "$repo/AGENTS.md" ] || { say "FAIL agents-link removed"; fails=$((fails+1)); }
      [ "$(cat "$FOREIGN/keep/data")" = precious ] || { say "FAIL agents-link clobbered"; fails=$((fails+1)); }
      say "OK agents-link refused, foreign link + data preserved"
      ;;
    real-conflict)
      [ "$code" -ne 0 ] || { say "FAIL real-conflict allowed"; fails=$((fails+1)); }
      [ "$(cat "$repo/CLAUDE.md")" = 'Distinct project instructions.' ] || { say "FAIL real-conflict clobbered"; fails=$((fails+1)); }
      cmp -s "$repo/before" "$repo/AGENTS.md" || { say "FAIL real-conflict altered AGENTS"; fails=$((fails+1)); }
      say "OK real-conflict refused, distinct instructions preserved"
      ;;
  esac
  say ""
}

say "########## SCENARIO: helper functional route (fresh/governed/owned-link + refusals)"
for k in fresh governed owned-link foreign-link agents-link real-conflict; do run_kind "$k"; done

# ---------------------------------------------------------------- help flags
say "########## SCENARIO: -h and --help (rewritten case branch)"
for flag in -h --help; do
  out=$("$HELPER" "$flag" 2>&1); code=$?
  say "$flag exit=$code first-line=$(printf '%s' "$out" | head -n1)"
  [ "$code" -eq 0 ] || { say "FAIL $flag exit"; fails=$((fails+1)); }
  printf '%s' "$out" | grep -q 'usage: fm-ensure-agents-md.sh' || { say "FAIL $flag usage"; fails=$((fails+1)); }
done
say ""

# ---------------------------------------------------------------- case-variant agents.md
say "########## SCENARIO: case-variant memory file refused (rewritten grep check)"
vindex=0
for variant in agents.md AGENTS.MD Agents.Md; do
  vindex=$((vindex+1))
  repo="$TMP/variant-$vindex"
  mkdir -p "$repo"
  printf 'lower\n' >"$repo/$variant"
  out=$(cd "$repo" && "$HELPER" . 2>&1); code=$?
  say "$variant exit=$code msg=$out"
  [ "$code" -ne 0 ] || { say "FAIL $variant accepted"; fails=$((fails+1)); }
  printf '%s' "$out" | grep -q "conflict: memory file is named $variant" || { say "FAIL $variant message"; fails=$((fails+1)); }
  [ ! -e "$repo/CLAUDE.md" ] || { say "FAIL $variant wrote pointer"; fails=$((fails+1)); }
done
say ""

# ---------------------------------------------------------------- guard: helper allowed live
say "########## SCENARIO: real transport strict inspection of the helper source"
W="$TMP/worker"
mkdir -p "$W"; git init -q -b main "$W"
printf '#!/usr/bin/env bash\necho hi\n' >"$W/ok.sh"
git -C "$W" add ok.sh
git -C "$W" -c user.email=t@e -c user.name=t commit -q -m init
BASE=$(git -C "$W" rev-parse HEAD)
git -C "$ROOT" show 2056a87aafa156949fbfed634b2162ae18139311:bin/fm-ensure-agents-md.sh >"$TMP/old-helper.sh"
chmod +x "$TMP/old-helper.sh"
guard() { # helper-path cmd
  jq -nc --arg c "\"$1\" ." --arg d "$W" '{session_id:"t",cwd:$d,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' \
    | env FM_WORKER_GUARD_ROOT="$W" FM_WORKER_GUARD_BASE="$BASE" "$CHECK" --claude --owner-pid none
}
oldout=$(guard "$TMP/old-helper.sh" 2>&1); oldcode=$?
say "pre-fix helper : exit=$oldcode err=$oldout"
newout=$(guard "$HELPER" 2>&1); newcode=$?
say "current helper : exit=$newcode err=$newout"
[ "$oldcode" -eq 2 ] || { say "FAIL pre-fix helper was not denied"; fails=$((fails+1)); }
printf '%s' "$oldout" | grep -q 'unsupported token at byte 2400' || { say "FAIL pre-fix byte-2400 reason missing"; fails=$((fails+1)); }
printf '%s' "$oldout" | grep -q 'UNPARSEABLE' || { say "FAIL pre-fix UNPARSEABLE missing"; fails=$((fails+1)); }
[ "$newcode" -eq 0 ] || { say "FAIL current helper denied"; fails=$((fails+1)); }
say ""
say "TOTAL FAILURES: $fails"
rm -rf "$TMP"
exit "$fails"
