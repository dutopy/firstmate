#!/usr/bin/env bash
# Live guard for the advisor tool at the worker launch boundary. It proves, with
# the INSTALLED Claude Code, that the exact command fm-spawn emits for a Claude
# worker removes the advisor tool from the request the model API receives, while a
# plain Claude session with the same user-level advisorModel setting still offers
# it. The model API is a local stub that records the request body and refuses it,
# so no model token is spent and no credential is used; the throwaway
# CLAUDE_CONFIG_DIR carries the advisorModel setting, so the captain's own settings
# are never read or written (their checksum is asserted unchanged).
# Refresh it after every Claude Code upgrade: it fails naming the version when the
# vendor tool or its disable control changes.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CLAUDE_ADVISOR_LIVE_E2E claude tmux python3

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-claude-advisor-live)
CFG="$LAB/claude-config"
SOCKET="fm-claude-advisor-$$"
SERVER_PID=''
REAL_SETTINGS="$HOME/.claude/settings.json"
settings_sum() { [ -f "$REAL_SETTINGS" ] && cksum < "$REAL_SETTINGS" || echo absent; }
SETTINGS_BEFORE=$(settings_sum)

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$CFG"
printf '%s\n' '{"advisorModel":"claude-opus-5-5","skipDangerousModePermissionPrompt":true}' > "$CFG/settings.json"
# Claude asks once before using a custom API key; pre-approve the stub key's last 20 characters.
STUB_KEY=sk-ant-stub-key-0123456789abcdef
printf '{"hasCompletedOnboarding":true,"customApiKeyResponses":{"approved":["%s"],"rejected":[]}}\n' "${STUB_KEY: -20}" > "$CFG/.claude.json"

cat > "$LAB/stub.py" <<'PY'
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0)))
        if 'messages' in self.path:
            with open(out, 'ab') as f:
                f.write(body + b'\n')
        reply = b'{"type":"error","error":{"type":"invalid_request_error","message":"stub"}}'
        self.send_response(400)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    do_GET = do_POST
    def log_message(self, *args):
        pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY
REQUESTS="$LAB/requests.jsonl"
: > "$REQUESTS"
python3 "$LAB/stub.py" "$REQUESTS" > "$LAB/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$LAB/port" ] && break; sleep 0.1; done
PORT=$(cat "$LAB/port")
[ -n "$PORT" ] || fail "stub model API did not start"

# run_in_tmux <name> <command...>: run under a pty and wait for the first model
# request, which is all the proof needs.
offered_tools() { # prints "advisor" when the last recorded request offers the advisor tool
  python3 -I -c '
import json, sys
last = None
for line in open(sys.argv[1], "rb"):
    if line.strip():
        last = json.loads(line)
if last is None:
    print("no-request")
else:
    print("advisor" if any("advisor" in json.dumps(t).lower() for t in last.get("tools", [])) else "no-advisor")
' "$REQUESTS"
}
run_and_wait() { # <name> <script>
  local name=$1 script=$2 i
  : > "$REQUESTS"
  tmux -L "$SOCKET" start-server \; set-option -g remain-on-exit on
  tmux -L "$SOCKET" new-session -d -s "$name" -x 200 -y 50 -c "$LAB" "sh '$script'" \
    || fail "$name: could not start tmux session"
  for i in $(seq 1 150); do
    [ -s "$REQUESTS" ] && break
    [ "$(tmux -L "$SOCKET" display-message -p -t "$name" '#{pane_dead}' 2>/dev/null)" = 0 ] || break
    sleep 0.2
  done
  [ -s "$REQUESTS" ] || tmux -L "$SOCKET" capture-pane -p -t "$name" 2>/dev/null | head -30 >&2
  tmux -L "$SOCKET" kill-session -t "$name" >/dev/null 2>&1 || true
  [ -s "$REQUESTS" ] || fail "$name: claude $CLAUDE_VERSION sent no model request; CLAUDE_CONFIG_DIR store: $(cat "$CFG/.claude.json")"
}
preamble() {
  printf '%s\n' "export CLAUDE_CONFIG_DIR='$CFG' ANTHROPIC_BASE_URL='http://127.0.0.1:$PORT' ANTHROPIC_API_KEY='$STUB_KEY'" \
    "unset CLAUDE_CODE_DISABLE_ADVISOR_TOOL" "cd '$1'"
}

# Spawn a real Claude ship worker through fm-spawn and capture its launch command.
HOME_DIR="$LAB/home"
PROJ="$LAB/project"
WT="$LAB/wt"
FAKEBIN=$(make_spawn_fakebin "$LAB/fake")
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ" "$WT" wt-advisor
fm_test_spawn_brief "$HOME_DIR" advisor-live
LAUNCH_LOG="$LAB/launch.log"
: > "$LAUNCH_LOG"
out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CFG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" advisor-live "$PROJ" --mode no-mistakes --yolo off)
status=$?
expect_code 0 "$status" "fm-spawn of a claude worker failed: $out"
[ -s "$LAUNCH_LOG" ] || fail "fm-spawn emitted no launch command"

# 1. Baseline: a plain session with the same advisorModel offers the tool, so the
#    probe cannot pass vacuously.
{ preamble "$WT"; printf '%s\n' "exec claude --dangerously-skip-permissions 'hello'"; } > "$LAB/baseline.sh"
run_and_wait baseline "$LAB/baseline.sh"
[ "$(offered_tools)" = advisor ] || fail "baseline claude $CLAUDE_VERSION did not offer the advisor tool with advisorModel set; the probe is vacuous"
pass "baseline: claude $CLAUDE_VERSION offers the advisor tool when advisorModel is set"

# 2. The emitted worker launch, even with a hostile ambient value, removes it.
{ preamble "$WT"; printf '%s\n' "export CLAUDE_CODE_DISABLE_ADVISOR_TOOL=0"; cat "$LAUNCH_LOG"; printf '\n'; } > "$LAB/worker.sh"
run_and_wait worker "$LAB/worker.sh"
[ "$(offered_tools)" = no-advisor ] || fail "worker launch on claude $CLAUDE_VERSION still offered the advisor tool"
pass "worker: the fm-spawn launch removes the advisor tool from the model request on claude $CLAUDE_VERSION"

[ "$(settings_sum)" = "$SETTINGS_BEFORE" ] || fail "the captain's user-level Claude settings changed during the test"
pass "the captain's user-level Claude settings were not touched"
