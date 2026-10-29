# Remote-job live validation

Target: `1fb8dc3928e52363a151fed738c5884b7eafde03`; baseline: `81df10a03ed78be9118e86a2bc9d0497ef3d7b3e`.

**Result: no-go.** Normal operation improves substantially, but a non-consuming worker can still make submission block in the notification write.

## Environment and isolation

macOS Darwin 23.3.0, 16 logical CPUs, stock `/bin/bash` 3.2.57. Disposable git checkouts, account homes, state roots and simple executable jobs were created under the validation worktree. The real unmodified worker and sourceable staging API ran against these roots. No external accounts or operator data were used. No GUI surface changed, so visual captures are not applicable.

## Idle before/after bench

Each worker was allowed to start, then measured idle for 12 seconds with an empty queue. Native `proc_pid_rusage` system-time deltas include the worker and its reaped children; percentages below are relative to one logical CPU, not the whole host. Startup, shutdown and later submitted jobs are excluded from these deltas.

| Worker | Direct child fork events/s | System CPU, one CPU | Whole-machine normalized system CPU |
|---|---:|---:|---:|
| Baseline | 68.00 | 12.1095% | 0.7568% |
| Target, FIFO | 0 | 0.0790% | 0.00494% |
| Target, unusable FIFO | 0.917 | 0.1780% | 0.01112% |

Process events were observed using macOS kqueue `EVFILT_PROC/NOTE_FORK`. Baseline figures are **lower bounds on process creation**, counting direct worker forks rather than every descendant and allowing event coalescing. The target FIFO worker produced no direct fork events during the observed idle window. These are local single-worker measurements, not a reproduction of the three-worker, four-core hub's host-wide sar figures. The 12-second window does not cover the 60-second maintenance sweep.

The initial attempt to follow all descendants with kqueue `NOTE_TRACK` failed because macOS does not support that option. DTrace was also attempted and refused with “DTrace requires additional privileges”; no privilege escalation was attempted. Fork-only kqueue observation and native CPU counters supplied the bench evidence without changing system configuration.

Both target variants refreshed `worker.ready` throughout the idle interval and passed the real `fm_remote_job_probe` after more than ten seconds.

## Job pickup and fallback

Six jobs were staged through the real public API in each target configuration. Every job executed its disposable command and persisted `ran` to the requested output file.

- FIFO: idle read returned 187–236 ms after staging began, around staging completion. Observable job side effect appeared 681–904 ms after the publisher returned. Total staging-to-side-effect latency was 877–1092 ms.
- Unusable FIFO: replaced the FIFO with a regular file before starting the worker. All six jobs still executed. Side effects appeared 1.280–2.105 seconds after publication returned, including command validation and launch overhead.

The focused existing executable test `TMPDIR="$PWD/.validation-tmp" /bin/bash tests/fm-remote-job-active-wait.test.sh` also passed. It launches the real worker and checks same-home serialization and prompt follow-on scheduling in FIFO and fallback modes, publisher and worker stderr preservation, idle marker lifecycle, and a 70,000-notification burst while the marker says no worker is waiting. Its transcript is `active-wait.log`.

## Reproduced failure: suspended idle reader blocks publication

The disposable real worker reached `worker.waiting=1`, then received SIGSTOP to simulate an unresponsive reader. Notifications were issued using the real `fm_remote_job_wake_worker` API, with no manual marker fabrication or direct FIFO writes. Progress stopped after approximately 8,100 notifications.

A new real `fm_remote_job_stage` invocation durably queued its job, but did not return within four seconds. Reading the FIFO via a nonblocking read-only descriptor confirmed **8,192 buffered notification bytes**. Draining those bytes allowed the staging invocation to return successfully **while the worker was still stopped**. Resuming the worker then executed the queued job. The reproduction was repeated and consistently blocked; the final run records the drain-based causal check.

This distinguishes a product write blockage from slow job validation, queue corruption, or a fixture setup failure. The marker correctly describes where the stopped worker last waited, but does not reserve pipe capacity or guarantee that the worker can consume a notification. The blocking `printf` at `bin/fm-remote-job-lib.sh:473` therefore still violates the requirement that wake publication cannot block staging. Any correction must preserve the recorded marker-based decision, Bash 3.2 support and fork-free idle path; this test phase did not replace that design.

## Commands and retained evidence

- `TMPDIR="$PWD/.validation-tmp" /bin/bash tests/fm-remote-job-active-wait.test.sh`
- `python3 .validation-tmp/live_check.py`
- `python3 .validation-tmp/stalled_publisher.py`
- `dtrace -qn 'syscall::fork:return { exit(0); }'` (permission diagnostic only)

The disposable Python drivers are retained alongside this report. To reproduce, copy them into `.validation-tmp/` under an isolated worktree and run the commands above, updating the evidence directory constant if necessary. JSON records and product stderr logs are retained. No repository-wide suite, linter, formatter, static analysis, push, PR, or CI phase was run. Disposable worktree data was removed after evidence collection; source files were not changed.
