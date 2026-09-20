# Merge one observation pass into the durable proposal ledger.
#
# Input: the slurped ledger array (jq -s).
# $cands: candidate records observed by this scan, as an array.
# $today: the caller's UTC date, YYYY-MM-DD.
# $now: the caller's epoch seconds.
# $stale_secs: how long a proposed entry may go unobserved before it is superseded.
#
# The contract this program owns:
#   - a decided entry (accepted, declined, superseded) is never revived and its
#     evidence stays frozen at decision time, so a declined idea is never
#     re-proposed;
#   - a still-proposed entry is refreshed in place from the newest observation;
#   - a proposed entry whose evidence stopped appearing is superseded instead of
#     silently dropped, so its record survives a source that scrolled away.
. as $ledger
| ($ledger | map(.id)) as $known
| ($ledger
   | map(. as $old
         | ($cands | map(select(.id == $old.id)) | first) as $c
         | if $c == null then $old
           elif $old.state == "proposed" then
             $old + { title: $c.title,
                      change: $c.change,
                      cost: $c.cost,
                      repo: $c.repo,
                      theme: $c.theme,
                      evidence: $c.evidence,
                      count_lines: $c.count_lines,
                      count_tasks: $c.count_tasks,
                      last_seen: $today,
                      last_seen_epoch: ($now | tonumber),
                      scans: (($old.scans // 1) + 1) }
           else $old
           end)) as $refreshed
| ($cands
   | map(select((.id as $id | ($known | index($id))) == null)
         | . + { state: "proposed",
                 first_seen: $today,
                 last_seen: $today,
                 last_seen_epoch: ($now | tonumber),
                 scans: 1,
                 decided_at: null,
                 decided_by: null,
                 reason: null,
                 work: null })) as $fresh
| (($refreshed + $fresh)
   | map(if (.state == "proposed")
           and ((($now | tonumber) - (.last_seen_epoch // 0)) > $stale_secs)
         then . + { state: "superseded",
                    decided_at: $today,
                    decided_by: "lane",
                    reason: "evidence no longer observed in the records" }
         else .
         end))
| .[]
