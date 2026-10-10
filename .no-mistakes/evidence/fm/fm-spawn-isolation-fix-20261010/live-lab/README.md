# Live lab: fm-spawn.sh isolation wait / allocator visibility (head f784de8)
Lab (all test-owned, under /tmp/fm-lab-*, removed afterwards): git repo with treehouse.toml max_trees=1 root=".";
private tmux server (TMUX_TMPDIR in lab, session "firstmate"); FM_HOME sandbox; run.sh drives the REAL bin/fm-spawn.sh
(/bin/bash 3.2) with real tmux + real treehouse v3.1.0. FM_GATE_REFUSE_BYPASS=1 (documented sandbox hatch) needed because
the gate sets NO_MISTAKES_GATE. Codex harness launched in lab panes only; killed at cleanup. Backend: tmux (Herdr NOT used).
Production fleet, ~/.hermes and any existing treehouse pool untouched.
1. Full pool (live, real): lab-a spawn ok (pool 1/1 in-use); lab-b -> exit 1 in ~9s: "treehouse get failed (exit 1) ... all 1 worktrees are in use or dirty (max_trees = 1)..." (s1-full-pool.txt). lab-a slot unchanged.
2. Default wait (live, real; allocator slowed by PATH shim sleeping 120s, a test double of treehouse timing only): exit 1 after 60s "within 60s" (s2-default60.txt).
3. Env wait: FM_SPAWN_ISOLATION_WAIT_SECS=5 -> "within 5s", exit 1 (s3-wait5.txt; cause was slow zsh startup, not shim); =40 w/ 8s delayed get -> success (s2-s5-...txt).
4. Invalid 0/abc/5000/-3 -> exit 1 immediately, window count and state unchanged (s4-invalid.txt).
5. Stale result file from another attempt planted (.lab-d.treehouse-get.99999.1.result=1): spawn still succeeded after 8s delay, pane first at project (transient) then isolated -> settle unchanged; stale file untouched (s2-s5-...txt).
Limits: real stale tmux scrollback not separately forced (fresh windows); stuck-on-primary-checkout and stale-first-read cases remain covered only by tests/fm-spawn-worktree-settle.test.sh (fake tmux); Herdr backend not exercised.
