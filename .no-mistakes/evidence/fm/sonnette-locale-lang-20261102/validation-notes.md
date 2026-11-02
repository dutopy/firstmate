# Remote doorbell locale validation

## Setup and scope

Ran the checked-out `fm-remote-job-worker.sh --serve` with a disposable HOME, FM_HOME, remote-job queue and TMPDIR inside the worktree. Its normal `env -i LANG=C` child environment executed the tracked `fm-remote-secondmate-control.sh send rsm ...` through the real queue. Bash on its composed PATH was GNU Bash 5.3.9. No SSH connection or operator credentials were used.

Ran installed Herdr 0.9.5 as an isolated headless `fm-lab-locale` session with a private config, non-login shell, and private HOME. An absolute config directory initially exceeded macOS's Unix socket path limit; a worktree-relative private config fixed setup. A small executable wrapper mapped only the control command's required `fm-remote` namespace to `fm-lab-locale`, invoking the real CLI through `fm-herdr-lab.sh run`. It did not simulate Herdr APIs.

A real Pi terminal UI ran in a real Herdr pane with no tools, extensions, context files, external credentials, or startup network. Its model dependency was a disposable localhost OpenAI-compatible response endpoint. This endpoint logged actual requests arriving from Pi and returned a fixed acknowledgement; it did not replace Firstmate, its worker, its inbox, Herdr, or Pi. Initial attempts without model configuration reached Pi but could not preserve the prompt visibly; these were not counted as successful evidence runs.

## Results

- Ten actual queued sends returned exit 0, retained ten distinct multiline UTF-8 steer bodies, and generated ten receiver-side HTTP requests. Every request's newest user message was the identical constant doorbell. None contained the steer body. The real Pi terminal rendered the doorbell and response. `remote-delivery-jobs.txt`, `persisted-steers.txt`, `receiver-doorbells.txt`, and `pane.html` show these contracts.
- Re-sending the exact first request after moving its record to `handled/` reported already acknowledged, retained exactly ten records, and generated no additional receiver request.
- A genuine isolated home containing ESC retained the new steer durably but refused its doorbell; the receiver request count remained unchanged. This is the expected safety rejection, not the locale regression.
- Executing the pre-change doorbell helper from the base commit, with the base versions of all changed supporting libraries and LANG/LC_ALL absent, produced substitution exit 139 on Bash 5.3.9. Executing the checked-out helper identically produced exit 0. See `baseline-reproduction.txt`.
- `HOME="$PWD/.local-test/account" TMPDIR="$PWD/.local-test/tmp" bash tests/fm-task-inbox.test.sh` completed successfully, including the new env-i test on Bash 3.2 and 5.3.9. The first attempt exceeded a 180-second command limit near the urgent-watcher tail; repeating the same file with a 600-second allowance completed, with no assertion failures. No full repository suite, linter, formatter, or static analysis was run.

The worker readiness race in the initial disposable setup was corrected by waiting for `worker.ready` before staging. All serving workers, the local response endpoint, and the isolated Herdr session were stopped; disposable data and drivers were removed from the worktree. Driver copies are retained alongside this evidence for inspection. `pane.html` is the actual terminal text rendered as HTML, not a native screenshot; the change alters shell environment/delivery, not visual layout.
