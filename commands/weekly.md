Create a weekly review note in the Obsidian vault, synthesizing the past week's daily notes.

**Vault:** `$VAULT`

If `$ARGUMENTS` specifies a week (e.g., "last week", "2026-W15"), use that. Otherwise default to the current week (Monday through today).

---

## 1. Calculate the week's date range

```bash
if [ -n "$ARGUMENTS" ]; then
  # Parse explicit arg. Accept "YYYY-WXX" (e.g., "2026-W14"), "last week", or a Monday date.
  # The agent should resolve $ARGUMENTS to:
  #   - week: e.g., W14
  #   - year: e.g., 2026
  #   - monday: YYYY-MM-DD (the Monday of that ISO week)
  #   - sunday: YYYY-MM-DD (the Sunday of that ISO week, for completeness)
  # Note: BSD date can compute an ISO Monday with:
  #   date -j -f "%G-W%V-%u" "2026-W14-1" "+%Y-%m-%d"
  # If that fails on the agent's host, compute manually: Jan 4 of <year> is always in W1;
  # the Monday of W1 is Jan 4 minus its weekday-minus-1; add (week-1)*7 days for the target Monday.
  :
else
  # Current ISO week number and year
  echo "week=W$(date +%V)"
  echo "year=$(date +%Y)"
  # Monday of current week
  echo "monday=$(date -v-$(date +%u)d +%Y-%m-%d 2>/dev/null || date -v-$(($(date +%u)-1))d +%Y-%m-%d)"
fi
```

The week identifier for the output filename is `<year>-W<week_number_zero_padded>` (e.g., `2026-W16`).

---

## 2. Find and read the daily notes for this week

Daily notes live at: `Daily Notes/YYYY/MM-MMMM/YYYY-MM-DD-dddd.md`

**If reviewing the current week:** read notes from Monday through today.

**If reviewing a completed week (via `$ARGUMENTS`):** read notes from Monday through Sunday of that ISO week. Note that a week may straddle two months — pull dailies from both `MM-MMMM` folders if needed (e.g., W14 of 2026 has Mar 30–31 in `03-March/` and Apr 1–5 in `04-April/`).

Skip days with no note. Extract all three sections from each: "Yesterday, I", "plan for today", and "struggling with".

---

## 3. Also check ICM for the week's cross-session work (optional)

If the `icm_memory_recall` MCP tool is available, use it with a query like "work completed tickets PRs decisions this week" to surface anything the agent team or other sessions recorded that may not have made it into daily notes (e.g. `/implement` runs, decisions, resolved errors).

When backfilling an older week, lean on the daily notes as the primary source — ICM is supplemental and reflects when things were stored.

---

## 3b. Corroborate with live data (current week only)

For the **current** week, pull the same shared gatherer `/daily`, `/eod`, and `/sitrep` use — with a 7-day window — so "Shipped & Completed" reflects actual merged PRs and issue tracker state, not just what made it into the daily notes:

```bash
~/.claude/lib/workspace-context.sh --since "7 days ago" --jira-days 7 --recent-days 7
```

(A 7-day **calendar** window is intentional: weekends are normally empty, so they add nothing — but if you were on-call and shipped over a weekend, you *want* that captured.) Read:
- `prs_recent` — PRs merged/opened this week → the backbone of **Shipped & Completed**.
- `jira_recent` — tickets that moved to Done/Code Review this week.
- `git` — commits across repos corroborating the above.
- `prs_authored` — still-open PRs; note any with `staleDays >= 2` (working days, not draft, not freshly bumped) as carryover candidates for **Next Week**.

**Skip 3b when backfilling an older week** — the gatherer reflects *now*, not the historical week; daily notes remain the source of truth there.

---

## 4. Synthesize the weekly review

Write a review with these sections:

```markdown
---
created: <today's date>
week: <YYYY-WXX>
theme-tag:: <comma-separated short slugs derived from Themes, e.g. observability, auth-improvements>
---
tags:: [[+Weekly Reviews]]

# Week of <Monday date> — <YYYY-WXX>

## Shipped & Completed
- [PRs merged, tickets closed, features shipped — with ticket/PR numbers where known]

## Key Work
- [Significant things worked on, even if not yet shipped]

## Meetings & Discussions
- [Notable meetings, design reviews, 1:1s, planning sessions]

## Wins
- [Highlights worth remembering — things that went well]

## Learning & Growth
- [New concepts understood, skills practiced, useful conversations, things that clicked — informal growth counts, not just formal learning]

## Struggles & Blockers
- [Patterns from the "struggling with" sections; recurring blockers]

## Themes
- [1–3 recurring topics or areas of focus this week — use these to derive theme-tag:: slugs in frontmatter]

## Next Week
- [ ] [Key priorities or carryover items for next week]
```

Keep each section tight — bullets, not prose. Quality over completeness.

**Linking rule:** Link all ticket references in your tracker's URL format (Jira example: `[PROJ-123]($JIRA_BASE_URL/browse/PROJ-123)`). Link PR references as `[PR #N](url)` using the actual URL.

**Backfill note:** When backfilling an older week, the synthesis is necessarily lighter — live tools (GitHub/issue tracker state) reflect *now*, not *then*. Lean on the daily notes as the primary source. It's fine to write a shorter review for backfilled weeks; consistency of structure matters more than parity of depth.

---

## 4b. Groom the Task Backlog

(Skip when backfilling an older week — grooming only makes sense for the current backlog.)

Read `$BACKLOG_FILE` and surface hygiene issues — present as a short list, act only on confirmation:
- **🔥 Warm gone stale** — items with `since` more than ~2 weeks ago. Prompt: schedule it, cool it to ❄️, ice it, or drop it. Warm is meant to be transient, not a graveyard.
- **❄️ Cool piling up** — if Cool has grown large, flag it; offer to promote a few worth doing or drop ones that no longer matter.
- **🔁 Recurring slipping** — any recurring item whose `last` is well overdue for its cadence (wasn't spawned when due).
- **📥 Triage not empty** — anything still sitting uncategorised; offer to sort.

Feed anything still relevant into the review's **Next Week** section as concrete `- [ ]` items. Only edit the backlog with your confirmation.

---

## 5. Write the review note

Write to: `Areas/Career Development/Weekly Reviews/<YYYY>/<YYYY-WXX>.md`

Full path: `$VAULT/Areas/Career Development/Weekly Reviews/<YYYY>/<YYYY-WXX>.md`

Create the directory if needed (Write tool handles this automatically).

---

## 6. Confirm

Report where the note was written and ask if there's anything to add or adjust.
