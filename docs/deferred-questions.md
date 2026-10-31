# Deferred questions (Claude primary)

A Claude primary that calls `AskUserQuestion` blocks its turn until the captain answers.
No `Stop` event fires while that prompt waits, so the `Stop`-owned watcher re-arm in `bin/fm-claude-stop-autoarm.sh` never runs and fleet supervision stops for as long as the captain is away.
Measured on one home, a single unanswered question cost seven and a half hours of supervision overnight and 46 to 80 minutes several times during the day.

Deferred-answer mode is the opt-in fix.
`bin/fm-deferred-question.sh` owns the mechanism, its exact contracts, and its state format in its header.

## Enabling

The mode is off by default and per home.

- Create the local, gitignored `config/deferred-questions` file to enable it.
- `FM_DEFERRED_QUESTIONS` overrides the file: `1`, `on`, `true`, or `yes` enables, any other non-empty value disables, and unset or empty defers to the file.
- Each line of that file reading `command:<cmd>` adds a notification command, run detached through `sh -c` with a one-line summary as `$1` and the JSON record on stdin; other lines, including `#` comments, are ignored.

```sh
# config/deferred-questions
command:terminal-notifier -title Firstmate -message "$1"
```

The flag is a home-local preference and is not inherited by secondmate homes.

## Behavior

The tracked `.claude/settings.json` registers two Claude hooks.
Both are inert under Grok, which loads Claude-compatible settings, because the mode relies on Claude-specific hook output.

When the mode is on and the primary calls `AskUserQuestion`, the `PreToolUse` hook:

1. Writes the questions to a durable record under `state/deferred-questions/`.
2. Starts every configured notification command without waiting for it.
3. Answers the tool call itself: an `allow` decision whose `updatedInput` echoes the questions and maps each one to a `DEFERRED:` answer, plus `additionalContext` telling the primary the captain has not answered.

The turn then continues and ends normally, so the `Stop` hook re-arms supervision as it does after any other turn.

At every later prompt that is not an operational input, the `UserPromptSubmit` hook lists each pending record as added context and marks it as re-surfaced.
That prompt is not proof the captain has returned.
The primary restates the question in plain chat and runs `resolve` only after the captain answers there.
It never calls `AskUserQuestion` again for a deferred question.
It runs even after the mode is turned off, so records from an enabled period are never stranded.
Firstmate's own operational inputs, which all begin with U+2063, are never treated as captain messages.

While the mode is on, the hook never hands a call back to Claude Code's blocking prompt: that reopens the gap this mode exists to close.
A call whose question texts match a pending record reuses that record instead of writing a second one.
Only `resolve` closes a record.

When the captain answers in plain chat, the primary closes the record itself:

```sh
bin/fm-deferred-question.sh list
bin/fm-deferred-question.sh resolve <id>   # or --all
```

Resolved records move to `state/deferred-questions/resolved/`.

## Scope

The hooks act only in a genuine primary or secondmate home, using the same `fm_primary_scope_matches` test as the other primary guards.
A crewmate or scout in a linked task worktree inherits the tracked settings but the hooks stay inert there, so a worker's own prompts are never deferred.
Missing `jq`, malformed hook input, or a failed record write also leaves the call untouched, which means Claude Code shows the ordinary blocking prompt exactly as it did before this mode existed.

## Limits

These are what Claude Code itself documents and what this mode can and cannot promise.

- Claude Code documents that a `PreToolUse` hook answers `AskUserQuestion` by returning `allow` with `updatedInput` holding the original `questions` and an `answers` map; returning `allow` alone does not skip the prompt.
- The documented `answers` value is "the selected option label".
  The `DEFERRED:` text is not an option label; Claude Code 2.1.316 accepted it and presented it to the model as the answer, but a later version could validate answers more strictly.
  The `additionalContext` carries the same meaning independently, so a stricter version would still not let the model read the deferral as a choice.
- The `defer` permission decision, which would pause the tool call for real, is honored only in non-interactive `claude -p` runs; interactive sessions ignore it, which is why this mode answers the call instead.
- A deferred question is never actually put to the captain inside Claude Code.
  The record, the notification command, and the primary restating it in plain chat are the only ways the captain learns of it.
- `UserPromptSubmit` also fires for scheduled tasks, background subagent reports, and cross-session messages, which Claude Code does not mark as distinct from a typed captain prompt; those can re-surface a question early.
- A deferred question is answered only through plain chat plus `resolve`, so the captain must read chat for it; the mode never reopens the blocking prompt.
- The hook's own timeout is 30 seconds for `PreToolUse` and 15 for `UserPromptSubmit`; a timed-out hook falls back to Claude Code's ordinary behavior, a blocking prompt or a prompt without added context.
- Questions asked while the mode is off, and `ExitPlanMode` approvals, still block as before.

## Verification

`tests/fm-deferred-question.test.sh` owns the behavior matrix: default-off inertness, the env override, the deferred `allow` shape and record, scope, notification commands, re-surfacing, record reuse for an identical call, `list` and `resolve`, and the tracked settings registration.
`tests/fm-turnend-guard.test.sh` proves both tracked entries stay inert under Grok and live under Claude.

A live interactive check on Claude Code 2.1.316 in a fixture home showed the deferred answer reaching the model, the turn completing with the `Stop` hook firing, and the next captain message re-surfacing the question.
