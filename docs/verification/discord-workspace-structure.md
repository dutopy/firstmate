# Discord workspace - applied live structure

Applied structure of the captain's private Discord workspace, read from the
Discord API on 2026-09-20. Contract:
[`../discord-workspace.md`](../discord-workspace.md). Proofs:
[`discord-workspace-activation.md`](discord-workspace-activation.md).

Three internal workspaces are active and equal-rank - System / Firstmate,
ProApplis, Folium - and share one template: one `#exchanges` forum, and at least
one `#artifacts` forum per project category. A task belongs to exactly one
project category, so its forum is what selects the context.

| lane | guild | `#exchanges` | project category | `#sessions` | `#artifacts` |
| --- | --- | --- | --- | --- | --- |
| System / Firstmate | `1525898345338372136` | `1550146033399373824` | Firstmate & Supervision | `1550358900912689162` | `1550358995255042098` |
| System / Firstmate | `1525898345338372136` | - | Hermes Runtime & Kanban | `1550359065379475466` | `1550446379157954640` |
| System / Firstmate | `1525898345338372136` | - | Infrastructure VPS | `1550359088905588797` | `1550446382148624456` |
| ProApplis | `1508049843765907597` | `1548016026610835507` | ProApplis Core | `1550446419511349359` | `1548016040427126834` |
| Folium | `1549540411562008787` | `1550358497605066795` | Mapping SED / ShippingBo | `1550358505645547651` | `1550358511773556776` |
| Folium | `1549540411562008787` | - | Communication & Emails | `1550358769446420611` | `1550446457528524851` |

Project routing (`config/discord-session-mirror.json`): `atelier` -> Firstmate &
Supervision, `dutopy-config` -> Infrastructure VPS, `hermes-agent` -> Hermes
Runtime & Kanban, `proapplis` -> ProApplis Core, `proapplis-folium` -> Mapping
SED / ShippingBo.

Undo: this record creates nothing. The activation's only live creations are the
task's session thread and this artifact's thread; each is removed with
`DELETE /channels/{thread_id}`, touching no other resource.
