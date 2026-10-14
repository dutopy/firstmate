# Task-worker destructive-command guard

This document is the authoritative human-readable contract for the guard that keeps a Firstmate-launched Claude or omp task worker from killing or deleting what is not its own.
`bin/fm-worker-guard-policy.mjs` is the single decision owner.
`bin/fm-worker-guard-pretool-check.sh` is the stable hook transport.
`bin/fm-worker-guard-omp-ext.ts` is the omp adapter.
Shell lexing is the shared parser owned by `bin/fm-arm-command-policy.mjs`.
Behavior is proven by `tests/fm-worker-guard.test.sh` (portable) and `tests/fm-worker-guard-live-e2e.test.sh` (installed Claude and omp, opt-in).

## Why this exists

A task worker once ran `pkill -f chrome-headless-shell`, `pkill -f daemon.py`, and similar patterns, and routed around a refused `rm` through a script.
Those patterns match processes and paths that belong to other workers' benches.
A written instruction was not enough, so the rule is enforced on the tool surface before the command runs.

## What is enforced

A worker may:

- kill a literal PID only on a joint proof, all of it required: the process is alive and belongs to the worker's own user, its physical current working directory is inside the worker's isolated copy or a task-owned root, and its command line is coherent with that, meaning no later path argument (including an `--option=value` value or a `..` traversal from its cwd) resolves outside the copy, a task root, or a system location (the executable itself may live anywhere);
- kill its own job (`$!`, `%N`, `$$`, or a variable assigned from `$!` in the same command), send signal 0, or kill a PID that no longer exists;
- `rm -r` paths that resolve inside its isolated copy or inside the task-owned scratch root `/tmp/fm-<id>`.

A worker may not:

- run `pkill`, `killall`, `fuser -k`, `tmux kill-*`, `launchctl kill/stop/remove`, `herdr server|session stop|delete`, or `xargs kill`;
- kill a PID it cannot prove, including process groups, `-1`, `0`, `1`, its own agent or supervisor chain, `kill $(pgrep ...)`, and any non-literal PID;
- `rm -r` (or `find -delete`, `find -exec rm`) outside its copy, including `~user`, `~+` and `~-` paths and any unambiguous GNU long-option prefix such as `--rec`, on the copy root itself, through a symlink that leaves the copy, through `.*`, or through an expansion the guard cannot resolve without running it;
- reach any of the above through `bash -c`, `eval`, `echo ... | sh`, a heredoc, a script file it wrote, or inline code in python, node, ruby, perl, php, lua, or omp's `eval` tool.

A path prefix never counts as ownership: `copy6evil` is not `copy6`.
Paths and process working directories are resolved physically (symlinks followed) before the comparison.
Nothing in the submitted command or in a scanned script is executed, sourced, or expanded.
The only processes the guard starts are `ps`, `lsof`, and `git rev-parse` to read facts.

## Indirect execution

The shell walk recurses into groups, substitutions, `-c` payloads, `eval` arguments, `env -S` payloads, here-documents, here-strings, literal `echo`/`printf`/`cat <<` pipes into a shell, and files written by `cat > f <<EOF` or `tee f` earlier in the same command line.
It tracks `cd` (including `builtin cd`), literal variable assignments, aliases, and `ln -s` links created earlier in the same command line, so a delete that goes through such a link is refused.
A brace group that starts an argument (`rm -r {/a,b}`) is read as brace expansion, and option values (`bash -o pipefail -c`, `python -X opt -c`, `node --eval=CODE`) are skipped when finding the code.
The argument of `echo` and `printf` is text the shell may run, so only the leading `-n`, `-e`, `-E` options of `echo` are dropped.
A script file the worker runs is read; installed system locations (`/usr`, `/opt`, `/Library`, and similar) are skipped only when neither the file nor its directory is writable by the current user, so a user-writable `/opt/homebrew` or `/usr/local` is scanned.
The guard process environment may add colon-separated prefixes to that list with `FM_WORKER_GUARD_SYSTEM_PREFIXES` (launch state only, used by the tests).
For a script inside the copy:

- a file that is new, edited, or committed by the worker is scanned strictly, exactly like inline code;
- a file whose bytes hash to the same blob as the task base commit (`FM_WORKER_GUARD_BASE`, compared with `GIT_NO_REPLACE_OBJECTS=1` and no git config, so worker-controlled refs, filters, and config cannot launder it) is reviewed project code and is held only to the definitive broad motifs (`pkill`, `killall`, `xargs kill`, `kill $(pgrep ...)`), so ordinary project scripts that clean their own temp variables keep working.

Non-shell code is scanned statically for:

- `pkill`/`killall` names;
- inline `awk` programs and perl/ruby quote-like strings (`q()`, `qq()`, `qx()`, `%q()`, `%Q()`, `%x()`), which are analyzed like any other embedded string;
- a kill primitive next to process enumeration (`psutil.process_iter`, `pgrep`, `ps`, `lsof`, `/proc` walks);
- `os.kill`/`process.kill`/`Process.kill`/`kill` on a literal foreign PID, a group, or a non-literal PID that is not the `.pid` of a process the same code started;
- recursive deletion APIs on a literal path outside the copy, or a non-literal path;
- shell strings and argument lists embedded in the code (`subprocess.run(["pkill", ...])`, `os.system("...")`, `child_process.execSync("...")`), which are analyzed as shell;
- file enumeration (`os.walk`, `glob`, `listdir`, `iterdir`) next to per-file deletion, which is a recursive delete in disguise;
- opaque construction (`exec`, `eval`, `compile`, `__import__`, `getattr(os, ...)`, `base64`, `ctypes.CDLL`) next to a process or filesystem capability.

The shell walk also unwraps `busybox`, `nice`, `time`, `setsid`, `flock`, `chroot`, `unshare`, `strace`, `ltrace`, `watch` and similar wrappers, reads the `-c` string of `su`, `runuser`, `script`, `sg` and `flock`, and reads the job text given to `at` and `batch`, denies `-c` code produced entirely by a substitution and scripts produced by a process substitution (`bash <(curl ...)`), reads the remote command of `ssh`, and holds `git clean` and `rsync --delete` to the same inside-the-copy rule as `rm -r`.

## Enforcement limits

The guard is a static, read-only policy.
It does not claim to contain arbitrary dynamically generated code.
What it deliberately refuses is opaque execution that sits next to a kill or delete capability.
It also refuses a command word it cannot read without running anything: a word containing a substitution or a variable that is not a single variable assigned earlier in the same command (`$(echo pkill) -f x`, `${P}ill`, `$a$b`).
Trap handlers, `"pk"+"ill"` string concatenation in embedded code (adjacent literals fold whatever the quote characters, joined by `+` or by plain adjacency), and aliased kill primitives (`k = os.kill`, `from os import kill`) are read or refused the same way.
What it cannot see:

- code reached only through an import, a plugin, a compiled binary, a package script (`npm run`, `make`), or a script outside the copy; a `pkill` or `rm -rf` placed in a `package.json` script or a Makefile runs unseen;
- single-file deletes with no enumeration (`rm file`, `os.remove(path)`), deletion by other tools (`mv x /dev/null`, `trash`), and commands run on another host or container (`docker exec`);
- the guard's own files and settings: a worker could edit `$FM_ROOT/bin` or the state directory with an editor tool if it left its copy, which the instructions forbid but no hook prevents;
- paths and PIDs produced at run time by variables from the environment, files, or other processes;
- a script changed between the guard reading it and the shell running it, and a PID recycled between the check and the signal (race windows are not closed);
- Claude's other tools: the guard covers every tool whose input carries a `command` string (Bash, Monitor, and any future one) and omp's `bash` and `eval` tools including `task` subagent calls, but a worker can still delete files through an editor tool, and the other verified harnesses (codex, opencode, pi, grok, kimi, cursor, gemini, muse, rovo, agy) carry no guard.

A stronger layer that closes these limits is an operating-system sandbox per worker (for example a `sandbox-exec` profile or a dedicated user), which is a separate decision.

## Fail posture

The transport fails closed: a missing `node`, policy, worker root, an unparsable hook payload, or a crashing policy denies the call, and the Claude hook command itself turns any outcome other than a clean allow, including an unset guard path, into exit 2, because Claude treats every other nonzero exit as a non-blocking error.
A PID is "dead" only when the kernel says so (`kill -0` reports no such process), never because a process listing came back empty.
The process table is read only when a kill needs it, and no process above the guard itself (its hook shell, the agent, its supervisors) is ever a valid target, whatever the agent binary is called.
`bin/fm-spawn.sh` refuses to launch a Claude or omp task worker when `node` or any guard file is absent, so closed never leaves a started worker unable to work.
There is no escape variable: the worker identity lives in the launch environment, which the worker's own shell cannot change for its already running hook process.

## Wiring

For a ship or scout worker, `bin/fm-spawn.sh` adds, only to the Claude and omp launch lines:

- `FM_WORKER_GUARD_BASE`, the commit of the worker's first launch, recorded as `guard_base=` in the task record so that `fm-control.sh relaunch` carries it forward unchanged; a relaunched task with no recorded base trusts no script until it is respawned;
- `FM_WORKER_GUARD_ROOT` (the isolated copy), `FM_WORKER_GUARD_EXTRA_ROOTS` (`/tmp/fm-<id>`), and `FM_WORKER_GUARD_LOG` (`state/<id>.worker-guard.log`, an append-only denial audit trail removed at teardown);
- Claude: `FM_WORKER_GUARD_CHECK` plus a `PreToolUse` hook with matcher `.*` in the inline `--settings` JSON, so every tool name reaches the policy and it filters by input shape;
- omp: `-e bin/fm-worker-guard-omp-ext.ts`, whose `tool_call` handler blocks with `{ block: true, reason }`.

A secondmate launch carries none of this.
A raw launch command carries none of this because its harness is unverified.

## False positives to expect

- A `$(...)` in inline code (`python3 -c "print('$(pwd)')"`) is accepted only for a bare fixed-metadata reader (`pwd`, `whoami`, `date +fmt`, `git rev-parse --show-toplevel`, ...); a path-qualified name, a name shadowed by an alias or function defined earlier, or any command line that assigns or exports `PATH` (including `env PATH=`) is refused.
- A command whose name comes from an unresolved variable or a substitution, including path-prefixed forms such as `$FM_ROOT/bin/tool`, `"$HOME/.local/bin/gh-axi"` and `$(npm bin)/tsc`; write the literal path, or assign the variable earlier in the same command so the guard can follow it.
- `rm -r` of a scratch directory under `/tmp` or `$TMPDIR` other than `/tmp/fm-<id>`; use a directory inside the copy or `/tmp/fm-<id>`.
- `shutil.rmtree(tmpdir)` or `fs.rmSync(dir, {recursive:true})` with a non-literal path in untracked or modified code.
- A modified or new script that uses `exec`/`eval`/`getattr(os, ...)` next to `os` or `subprocess`.
- Any script that mentions `pkill` or `killall` as a command, including inside a comment or a string, and a committed repository script that really calls them.
- `kill $PID` where `$PID` came from a pidfile or an earlier call; read the PID, then kill the literal number after `ps -o pid,ppid,command -p <pid>` confirms it.
- Killing a process the worker started from a directory outside its copy, or whose command line names a path outside the copy, a task root, or a system location (a browser given `--user-data-dir=/tmp/profile` is refused; give it a profile under the copy or `/tmp/fm-<id>`), even when it descends from the worker's own agent.
- Killing a process whose cwd, command line, or owner cannot be read, which is refused as unproven rather than guessed.
- Relative deletes after a `cd` whose target is a variable (the working directory becomes unknown).
- Relative paths resolve against the `cwd` the harness reports and against any `cd` earlier in the same command; both Claude 2.1.296 and omp 18.5.1 return to the session directory between bash calls (verified), so a `cd` in one call never affects the next.

## Rollout and rollback

New workers get the guard on their next spawn once this change is on the home's default branch and the home has been updated.
Already running workers are untouched: their launch environment and settings were fixed at spawn, and they pick up nothing until relaunched.
To roll back, revert the change; no per-home or per-worker configuration file is involved, and existing `state/<id>.worker-guard.log` files are ordinary leftovers removed by teardown.
The captain-private homes and the shared installed source need no configuration push: all guard files are tracked under `bin/` and `docs/`.
