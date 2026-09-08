# Agent-instruction routing

`AGENTS.md` is the sole canonical supervisor contract for this repository.
`CLAUDE.md` is a real two-line `@AGENTS.md` import pointer and must not carry independent instructions.
The tracked `.claude/skills` link points Claude at `.agents/skills`; the skill files remain the conditional-procedure owners.

## Ownership map

The consolidation changes discovery, not ownership.
The always-loaded role, safety, startup, routing, delivery, and skill-trigger obligations remain in `AGENTS.md`.
`docs/configuration.md` remains the owner of top-level operational-home schemas, while each producing script's header and help remain the owner of exact mechanics and mutations.
`docs/sessionstart-nudge.md`, `docs/subagent-guard.md`, `docs/turnend-guard.md`, and `docs/secondmate-parent-channel.md` retain their native session-start, delegation-boundary, turn-end-backstop, and parent-channel contracts respectively.
Harness-specific supervision text remains under `docs/supervision-protocols/`, and project instruction migration remains owned by `bin/fm-ensure-agents-md.sh`.
The public, contributor, and architecture pages below now route readers to this map instead of repeating the `CLAUDE.md` and skill-link compatibility details.

## Bounded inventory

This inventory covers the 14 tracked Markdown routing surfaces that mention the agent-instruction convention.
It is deliberately finite: it does not treat arbitrary project clones, private homes, generated files, or test fixtures as repository instruction surfaces.
The public `skills/stow/SKILL.md` is included because it teaches readers how project-level `CLAUDE.md` and `AGENTS.md` memory files relate; mechanics-only fixtures such as `docs/cd-guard.md` remain excluded.

| Surface | Role |
| --- | --- |
| `AGENTS.md` | Canonical always-loaded supervisor contract |
| `CLAUDE.md` | Compatibility pointer to `AGENTS.md` |
| `CONTRIBUTING.md` | Contributor-facing setup and maintenance pointer |
| `README.md` | Public setup pointer |
| `docs/architecture.md` | Maintainer architecture pointer |
| `docs/configuration.md` | Operator configuration pointer |
| `docs/scripts.md` | Script ownership pointer |
| `docs/secondmate-parent-channel.md` | Secondmate return-channel pointer |
| `docs/sessionstart-nudge.md` | Session-start contract pointer |
| `docs/subagent-guard.md` | Subagent boundary pointer |
| `docs/supervision-protocols/grok.md` | Grok-specific supervision pointer |
| `docs/supervision-protocols/unknown.md` | Fallback supervision pointer |
| `docs/turnend-guard.md` | Turn-end backstop pointer |
| `skills/stow/SKILL.md` | Public project-memory compatibility pointer |

Each row is a pointer or compatibility statement, not a second owner.
Operational detail belongs to the named script, skill, or documentation owner.

## Compatibility and migration

Existing clones that have a real `CLAUDE.md` pointer continue to resolve `AGENTS.md` without migration.
`bin/fm-ensure-agents-md.sh` owns creation and migration of project-level `AGENTS.md` and `CLAUDE.md` files; its exact pointer bytes and conflict behavior are the compatibility contract.
A repository-root `CLAUDE.md` remains a regular file matching the pointer emitted by that public helper.
A project-level `AGENTS.md` is project-intrinsic memory and is distinct from this repository's supervisor contract.
No repository instruction is moved, deleted, or inferred from a project-level file by this inventory.

Run `tests/fm-agents-routing.test.sh` to check the inventory, pointer shape, symlink target, and discoverability of the canonical owner.
