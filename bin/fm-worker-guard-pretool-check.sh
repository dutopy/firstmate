#!/usr/bin/env bash
# PreToolUse transport for the task-worker destructive-command guard.
#
# bin/fm-worker-guard-policy.mjs owns the decision; docs/worker-guard.md owns the
# contract, the false-positive catalogue, and the enforcement limits. This
# wrapper only locates Node and the policy, fixes the worker identity from
# firstmate-controlled launch state, and relays the verdict. It never executes,
# sources, or expands any byte of the submitted command.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-worker-guard-pretool-check.sh [--root R]
#   bin/fm-worker-guard-pretool-check.sh [--root R] --command '<cmd>' [--cwd D]
#   bin/fm-worker-guard-pretool-check.sh [--root R] --code '<src>' --lang python
#
# The worker's isolated copy comes from --root or, when absent, from
# FM_WORKER_GUARD_ROOT, which fm-spawn exports into the agent's launch
# environment (a model's bash tool cannot change the hook's environment).
# FM_WORKER_GUARD_EXTRA_ROOTS (colon separated) names extra task-owned scratch
# roots. --owner-pid defaults to "auto": the nearest claude/omp ancestor.
#
# Exit contract (Claude, Codex-style, and omp adapters all read it):
#   ALLOW - exit 0, no output.
#   DENY  - exit 2 and the reason on stderr; stdout stays empty.
# Unlike the primary-checkout seatbelts this guard FAILS CLOSED: a missing
# policy, missing Node, missing root, unparsable payload, or a crashing policy
# denies. bin/fm-spawn.sh
# refuses to launch a worker whose prerequisites are absent, so closed never
# means a worker that cannot start its day.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
POLICY="$HERE/fm-worker-guard-policy.mjs"

ARGS=()
HAVE_ROOT=0
HAVE_OWNER=0
HAVE_INPUT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude | --omp) shift; continue ;;
    -h | --help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    --root=*) HAVE_ROOT=1 ;;
    --owner-pid=*) HAVE_OWNER=1 ;;
    --command=* | --code=*) HAVE_INPUT=1 ;;
    --root | --owner-pid | --command | --code | --cwd | --lang | --home | --extra-root)
      # An option's value is a value even when it looks like an option
      # (`--cwd -h`, a command text of `--help`), so it is consumed here.
      case "$1" in
        --root) HAVE_ROOT=1 ;;
        --owner-pid) HAVE_OWNER=1 ;;
        --command | --code) HAVE_INPUT=1 ;;
      esac
      ARGS+=("$1")
      shift
      if [ "$#" -gt 0 ]; then ARGS+=("$1"); shift; fi
      continue
      ;;
  esac
  ARGS+=("$1")
  shift
done

deny() {
  echo "worker-guard [CONFIG]: $1; tool call refused. Append \`blocked: worker guard misconfigured\` to your status file." >&2
  exit 2
}

command -v node >/dev/null 2>&1 || deny "node is not available"
[ -f "$POLICY" ] || deny "policy $POLICY is missing"
[ "$HAVE_ROOT" -eq 1 ] || {
  [ -n "${FM_WORKER_GUARD_ROOT:-}" ] || deny "FM_WORKER_GUARD_ROOT is not set"
  ARGS+=(--root "$FM_WORKER_GUARD_ROOT")
}
[ "$HAVE_OWNER" -eq 1 ] || ARGS+=(--owner-pid auto)
if [ -n "${FM_WORKER_GUARD_EXTRA_ROOTS:-}" ]; then
  IFS=: read -r -a EXTRA <<<"$FM_WORKER_GUARD_EXTRA_ROOTS"
  for r in "${EXTRA[@]}"; do [ -z "$r" ] || ARGS+=(--extra-root "$r"); done
fi
[ "$HAVE_INPUT" -eq 1 ] || ARGS+=(--stdin-json)

# Claude blocks only on exit 2; any other nonzero exit is a non-blocking error
# and the tool would run anyway. Every outcome that is not a clean allow
# therefore leaves as exit 2, including a node crash or a failed policy import.
node "$POLICY" "${ARGS[@]}"
rc=$?
[ "$rc" -eq 0 ] && exit 0
[ "$rc" -eq 2 ] || echo "worker-guard [CRASH]: the policy exited $rc; tool call refused. Append \`blocked: worker guard failed\` to your status file." >&2
exit 2
