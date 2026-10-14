# Live product validation: disk cleanup simulation (SIMULATION ONLY)

Change under test: `bin/fm-disk-simulate.py` + `bin/fm-disk-simulate-{imac,vps,staging,ft}.sh`,
plus docs and the behavior suite. HEAD fix round (435d1bf4) drops the repeated
per-descendant `realpath` while keeping canonical direct-object exclusion.

Driver: `drive_disk_simulate.py` runs the shipped entry points from the worktree
against an isolated canonical `/private/tmp` layout, parses the emitted JSONL and
asserts both the decision/reasons and that no file is removed.

Result: **55/55 live assertions pass, 0 failures** across 15 scenario groups.

| # | Scenario | Result |
|---|----------|--------|
| A | staging named old release -> `candidate`, section-3 line 60, files survive | pass |
| B | iMac end-of-task artifact on a real pushed+landed git repo -> `candidate` line 54; unpushed work refuses | pass |
| C | FT always refuses (no whitelist/inventory authority) | pass |
| D | `--apply/--delete/--prune/--archive/--yes/--force` all refuse; nothing deleted | pass |
| E | private home `data/`/`state/` excluded via effective `FM_HOME`, `FM_ROOT_OVERRIDE`, `FM_DATA_OVERRIDE`, and symlink alias spelling | pass |
| F | protected descendants (`backups/`, `ms-playwright`) and symlink escape/descendant refuse | pass |
| G | regular-file object refuses `unsupported-object-type` (not a usage-proof reason) | pass |
| H | genuinely live non-root host observations cannot forge a candidate | pass |
| I | VPS `journal`/`temporary-file` refuse `native-retention-eligibility-unproven` | pass |
| J | Docker: unreferenced image -> candidate line 59; stopped-container reference refuses | pass |
| K | simulator unavailable+Shutdown -> candidate line 56; Booted refuses | pass |
| L | stale / empty / machine-mismatched / missing inventory refuse | pass |
| M | imported `argv` is data, never executed (no sentinel created) | pass |
| N | named exclusions Hermes, StorageBox, backups, restic, Documents, Desktop, Audio, ms-playwright, shared + `.wav/.pdf/.bak` descendants | pass |
| O | large-tree scan: HEAD and the pre-fix revision emit identical decisions; no slowdown (0.081s vs 0.093s over ~15.6k entries) | pass |

Representative candidate rows (real entry points, isolated layout):

```json
{"decision":"candidate","machine":"staging","kind":"staging.old-build","report_line":60,"reasons":[],"simulation_only":true}
{"decision":"candidate","machine":"imac","kind":"imac.task-artifact","report_line":54,"reasons":[],"simulation_only":true}
{"decision":"candidate","machine":"vps","kind":"vps.docker-image","report_line":59,"reasons":[],"simulation_only":true}
{"decision":"candidate","machine":"imac","kind":"imac.simulator","report_line":56,"reasons":[],"simulation_only":true}
```

Baseline / documented command:

- `bash tests/fm-disk-simulate.test.sh` -> exit 0, 21 `ok` groups.
- `bash bin/fm-test-run.sh tests/fm-disk-simulate.test.sh` -> `exit=0`, `failed=0`.
- `bash bin/fm-test-run.sh --list --changed --base d3add8ad4ac348ab5142acfb2a449d2d1b11e8b8`
  selects `tests/fm-disk-simulate.test.sh` for the changed disk-simulate files.
- The four entry points are executable and `--help` exits 0 with the shared contract.

No finding was raised: every scenario this change exposes is drivable and passes,
and the change introduces no new runtime surface beyond the shipped CLI.
