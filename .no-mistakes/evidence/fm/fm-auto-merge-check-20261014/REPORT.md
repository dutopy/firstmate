# Live validation: bin/fm-auto-merge-check.sh (PR B1)

Product driven: the real `bin/fm-auto-merge-check.sh` wrapper + `bin/fm_auto_merge_check.py`
+ the versioned `bin/fm-auto-merge-denylist.globs` + the installed `bin/size-gate.sh`,
run from the worktree under test. GitHub and no-mistakes are a disposable local stub
selected through `PATH`; the diff is a real git diff in a throwaway repository, and
`FM_HOME` points at a disposable home. Nothing outside the throwaway world was written.

Driver: `live_drive.py`  Results: `live_results.json`

| Scenario | Adversarial input | Observed |
| --- | --- | --- |
| S1 eligible docs edit accepts | real docs/**.md prose modification, 101 green checks, clean native review | exit 0 + JSON binding head/base/actor ids/size |
| S2 bin/ script fix refuses | edit `bin/fm-calm.sh` (the class F1 raised) | exit 1 `sensitive path`, stdout empty |
| S3 deny-list categories refuse | 29 paths: AGENTS.md, CLAUDE.md, GROK_BOT.md, .agents/skills, .github/workflows, hooks, config/, secrets/, bin/**, .no-mistakes.yaml, .greptile, .tasks.toml, .gitattributes, skills/** | all exit 1, stdout empty |
| S4 credential-like content refuses | AWS_ACCESS_KEY_ID=AKIA..., api_key, Authorization Bearer, passwd, BEGIN RSA PRIVATE KEY, GITHUB_TOKEN | all exit 1 `sensitive content` |
| S5 executable refuses | unchanged 0755 file edit and 100644→100755 mode change | both exit 1 `unclassified mode...` |
| S6 size/deletion bounds | >50 deletions refuses; exactly 50 accepts; 401 lines refuses; 16 files refuses | 1/0/1/1 as intended |
| S7 structural refuses | symlink addition, new-file addition, binary content | exit 1 |
| S8 non-green final head refuses | late-page FAILURE, IN_PROGRESS, NEUTRAL, check on old commit oid, zero checks | all exit 1, stdout empty |
| S9 identity/PR state refuses | author == merger, dirty merge state, draft | all exit 1 |
| S10 native contract | CI-ready monitoring (status running, review/pr completed, ci running, exact head) accepts; active fixer, pipeline_owned custody, open findings, missing evidence refuse | 0/1/1/1/1 |
| S11 read-only refusal | sensitive change | repo + disposable home byte-identical, no merge/run/respond call |
| S1 read-only acceptance | accepted change | only read calls (`GET`, read GraphQL checks, `gh api user`, `axi status`), no merge |

Corroborating targeted check: `tests/fm-auto-merge-check.test.sh` → `Ran 20 tests ... OK`.
