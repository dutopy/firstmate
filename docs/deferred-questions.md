# Deferred questions (Claude primary)

A Claude primary that calls `AskUserQuestion` blocks its turn until the captain answers.
No `Stop` event fires while that prompt waits, so the `Stop`-owned watcher re-arm in `bin/fm-claude-stop-autoarm.sh` never runs and fleet supervision stops for as long as the captain is away.

Deferred-answer mode is the opt-in fix.
This guide owns operator behavior and supported limits; `bin/fm-deferred-question.sh --help` owns exact hook, command, enablement, and state contracts.

## Enabling

The mode is off by default and per home.

- Create the local, gitignored `config/deferred-questions` file to enable it.
- Use `FM_DEFERRED_QUESTIONS` to override the file; accepted values are listed in `bin/fm-deferred-question.sh --help`.
- Add optional `command:` notification lines using the same help's notification contract.

```sh
# config/deferred-questions
command:terminal-notifier -title Firstmate -message "$1"
```

The flag is a home-local preference and is not inherited by secondmate homes.

## Behavior

The tracked `.claude/settings.json` registers two Claude hooks.
Both are inert under Grok, which loads Claude-compatible settings, because the mode relies on Claude-specific hook output.

When the mode is on and the primary calls `AskUserQuestion`, the `PreToolUse` hook:

1. Records the questions durably, or reuses a pending record with matching question texts.
2. Starts configured notifications only for a new record, without waiting for them.
3. Supplies a `DEFERRED:` answer and context explaining that the captain has not answered; the script header defines the exact hook output.

The turn then continues and ends normally, so the `Stop` hook re-arms supervision as it does after any other turn.

At every later prompt that is not an operational input, the `UserPromptSubmit` hook lists each pending record as added context and marks it as re-surfaced.
That prompt is not proof the captain has returned.
The primary restates the question in plain chat and runs `resolve` only after the captain answers there.
It never calls `AskUserQuestion` again for a deferred question.
The recovery hook runs even after the mode is turned off, so records from an enabled period are never stranded.
Firstmate's own operational inputs, which all begin with U+2063, are never treated as captain messages.

For valid calls with a writable store, the enabled hook continues to defer even after a non-operational prompt re-surfaces a question; failure cases are listed below.
Repeated calls do not count as answers, including a call that repeats only part of a multi-question record.

When the captain has answered every question in a record in plain chat, the primary closes that record itself:

```sh
bin/fm-deferred-question.sh list
bin/fm-deferred-question.sh resolve <id>   # or --all
```

Use `--all` only when all pending records have been answered.
Check resolution errors before treating a question as closed; the script header defines write-failure handling, including for `--all`.

## Scope

The hooks act only in a genuine primary or secondmate home, using the same `fm_primary_scope_matches` test as the other primary guards.
A crewmate or scout in a linked task worktree inherits the tracked settings but the hooks stay inert there, so a worker's own prompts are never deferred.
Missing `jq`, malformed hook input, or a failed record write also leaves the call untouched, which means Claude Code shows the ordinary blocking prompt exactly as it did before this mode existed.

## Limits

These are what Claude Code itself documents and what this mode can and cannot promise.

- Claude Code documents that a `PreToolUse` hook answers `AskUserQuestion` by returning `allow` with `updatedInput` holding the original `questions` and an `answers` map; returning `allow` alone does not skip the prompt.
- The documented `answers` value is "the selected option label".
  The `DEFERRED:` text is not an option label; Claude Code 2.1.316 accepted it and presented it to the model as the answer, but a later version could validate answers more strictly.
  The `additionalContext` independently says no choice was made, but it cannot guarantee that a stricter version will skip the blocking prompt.
- The `defer` permission decision, which would pause the tool call for real, is honored only in non-interactive `claude -p` runs; interactive sessions ignore it, which is why this mode answers the call instead.
- A deferred question is never actually put to the captain inside Claude Code.
  The record, the notification command, and the primary restating it in plain chat are the only ways the captain learns of it.
- `UserPromptSubmit` also fires for scheduled tasks, background subagent reports, and cross-session messages, which Claude Code does not mark as distinct from a typed captain prompt; those can re-surface a question early.
- A deferred question is answered only through plain chat plus `resolve`, so the captain must read chat for it; the mode never reopens the blocking prompt.
- The hook's own timeout is 30 seconds for `PreToolUse` and 15 for `UserPromptSubmit`; a timed-out hook falls back to Claude Code's ordinary behavior, a blocking prompt or a prompt without added context.
- Questions asked while the mode is off, and `ExitPlanMode` approvals, still block as before.

## Verification

`tests/fm-deferred-question.test.sh` owns the behavior matrix: default-off inertness, the env override, the deferred `allow` shape and record, failed-delivery rollback without deleting reused records, scope, notification commands, re-surfacing without reopening the blocking prompt, identical-call reuse, partial re-asks, `list` and `resolve`, resolution-write failure, and tracked settings registration.
`tests/fm-turnend-guard.test.sh` proves both tracked entries stay inert under Grok and live under Claude.

A live interactive check on Claude Code 2.1.316 in a fixture home showed the deferred answer reaching the model, the turn completing with the `Stop` hook firing, and the next captain message re-surfacing the question.
