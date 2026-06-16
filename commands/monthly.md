Create a monthly review note in the Obsidian vault, synthesizing the month's daily notes and weekly reviews.

**Vault:** `$VAULT`

If `$ARGUMENTS` specifies a month (e.g., "March", "April", "2026-04"), use that. **Otherwise default to the *last completed month*** — not the current month. (Monthly reviews are written after the month ends, so the current month is rarely what the user wants.)

---

## 1. Determine the month

```bash
if [ -n "$ARGUMENTS" ]; then
  # Parse explicit arg. Accept "April", "2026-04", "2026-04-April", or "04".
  # Resolve $ARGUMENTS to month/year/month_name and substitute below.
  :
else
  # Default: last completed month.
  echo "month=$(date -v-1m +%m)"
  echo "month_name=$(date -v-1m +%B)"
  echo "year=$(date -v-1m +%Y)"
  echo "month_folder=$(date -v-1m +%m-%B)"
fi
```

Resolve to: `month` (`MM`), `month_name` (`April`), `year` (`YYYY`), `month_folder` (`MM-MMMM`).

---

## 2. Determine which ISO weeks belong to this month

A week belongs to the month where the **majority of its working days (Mon–Fri)** fall. With 5 weekdays there's never a tie. Concretely:

- For each ISO week that overlaps the month, count Mon–Fri days that fall within `<year>-<month>-01` through `<year>-<month>-<last_day>`.
- If 3+ weekdays fall in this month, the week belongs here.
- Otherwise it belongs to the adjacent month.

This means the monthly review may include 1–2 daily notes from the previous or next calendar month (e.g., for April 2026, W14 includes Mar 30–31 because the rest of W14 is in April; W18 includes May 1 because the rest of W18 is in April). That's intended — keeps weekly reviews atomic and respects the rhythm of the working week.

List the weeks belonging to this month as `<YYYY-WXX>` identifiers (e.g., `2026-W14`, `2026-W15`, …).

---

## 3. Read the weekly reviews for those weeks (preferred spine)

For each week in the list above, read the corresponding weekly review file:
`Areas/Career Development/Weekly Reviews/<YYYY>/<YYYY-WXX>.md`

Weekly reviews are the **preferred source** because the synthesis work is already done. Use them as the spine of the monthly review.

If a weekly review for a given week does **not** exist, fall through to step 4 for that week's days.

---

## 4. Read daily notes only for weeks without a weekly review

For any week from step 2 that lacks a weekly review, read the daily notes for that week's days that fall within this month:

`Daily Notes/<YYYY>/<MM-MMMM>/` for in-month days, plus the previous/next month's folder for any boundary days that belong to a week assigned to this month (per step 2).

Extract the "Yesterday, I", "plan for today", and "struggling with" sections from each note.

---

## 5. Compute the headline numbers

```bash
# Working days logged: count of daily notes that exist for the month's date range
# (use the weeks-in-month range from step 2, not strict calendar)
ls "Daily Notes/<YYYY>/<MM-MMMM>/" 2>/dev/null | wc -l | tr -d ' '

# Plus any boundary-week dailies in the adjacent month folders
```

For PRs and tickets, query directly:

**PRs merged this month:**
```bash
for repo in $REPOS; do
  echo "=== $repo ===" && cd $SOURCE_DIR/$repo && \
    gh pr list --author @me --state merged --search "merged:<YYYY-MM-01>..<YYYY-MM-last_day>" --limit 50 \
    --json number,title,mergedAt,url 2>/dev/null
done
```

**Tickets closed this month:**
```bash
jira issue list --assignee me --project "${JIRA_PROJECT:-YOUR_PROJECT}" --status Done --updated-after "<YYYY-MM-01>" --updated-before "<YYYY-MM-last_day>" 2>/dev/null
```

Use these to fill the "Month in Numbers" section with real counts and a list of merged PRs / closed tickets — never guess or leave placeholders.

---

## 6. Check ICM for the month's observations (optional)

If the `icm_memory_recall` MCP tool is available, use it with a query like "work observations completed tickets PRs this month" to pull cross-session observations across your repos. This catches code-level work that may not be captured in dailies/weeklies.

---

## 7. Read the declared goals file

Read `Areas/Career Development/Goals/<YYYY>.md` (e.g., `Goals/2026.md`).

For each declared goal, extract: title, status, success criteria, and evidence list (theme-tags, ticket keys, repo references). Hold these for use in step 8 ("Goals & Progress" synthesis).

If the goals file does not exist, note that in the draft and skip the Goals & Progress section. Do not invent goals — declared goals are the user's responsibility to write.

---

## 8. Synthesize the monthly review (draft only — do not write yet)

Build a draft using this template. Bullets, not paragraphs. Quality over completeness.

```markdown
---
created: <today's date>
month: <YYYY-MM>
weeks: [<YYYY-WXX>, <YYYY-WXX>, ...]
---
tags:: [[+Monthly Reviews]]

# <Month> <YYYY> — Monthly Review

## Month in Numbers
- Working days logged: <count>
- Weekly reviews: <count of weekly review files for this month>
- PRs merged: <count> — <one-line list of the most significant ones>
- Tickets closed: <count> — <one-line list of the most significant ones>

## Projects & Themes
- [Major projects worked on this month and their status. Aggregate themes from the weekly reviews — themes that recurred across multiple weeks become headline themes; one-off themes get a brief mention.]

## Shipped
- [Features, fixes, and work that made it to production. Pull from weekly "Shipped & Completed" sections, deduped and grouped by project where helpful.]

## In Progress
- [Significant work that carried over into next month. Pull from latest week's "Next Week" plus any items that appeared in multiple weeks' Key Work without shipping. Include pre-shipping work too — research, scoping, design conversations — not just things with PRs attached.]

## Wins
- [Best moments and positive outcomes. Things that went well — process wins, outcome wins, collaboration wins. Aggregate from the weekly Wins sections.]

## Struggles
- [Recurring blockers and challenges. Patterns from weekly Struggles sections — items that persisted multiple weeks deserve emphasis. Note resolution status for each. Optionally split into "Still working on" and "Resolved with lesson" if there are clear examples of each.]

## Learning & Growth
- [New skills, patterns, or knowledge gained this month. Look for: new tools adopted, processes set up, technical concepts learned, feedback received and acted on, presentations given, cross-team pairings. Distinguish active growth (presented, paired, taught) from passive growth (attended, watched).]

## Goals & Progress
**Declared progress** — for each goal in `Goals/<YYYY>.md`, assess this month's movement:
- **<Goal title>** (status: <status>) — <one-line assessment of what moved, what didn't, evidence>
- ...

**Emerged vs declared** — name 1–2 things that consumed real time this month but don't appear in the declared goals. This delta is the most interesting signal in the doc — it surfaces either stale goals or invisible work.
- <theme or project> — <why it consumed time, why it isn't a declared goal, and whether the goals file should change>

If no goals file exists, render this section as: `_No declared goals file yet. Create `Goals/<YYYY>.md` to enable goal tracking._`

## Career Highlights
- [1–3 items most worth raising in a 1:1 with manager or in a self-review. Promotion-relevant work: cross-team impact, novel problems solved, leadership moments, work that demonstrates growth in scope or seniority. *Distinct from Wins* — Wins are about the month going well; Highlights are about your trajectory.]

## Next Month Priorities
- [ ] [Concrete priorities for next month. Pull from the latest weekly's "Next Week" and any longer-arc commitments surfaced during the synthesis.]
```

**Linking rule:** Link all ticket references in your tracker's URL format (Jira example: `[PROJ-123]($JIRA_BASE_URL/browse/PROJ-123)`). Link PR references as `[PR #N](url)` using the actual URL.

**Bootstrapping note:** If fewer than 3 weekly reviews exist for this month (e.g., the system started mid-month), add a brief italic note at the top of the doc: `_Note: this is a partial month — the journaling system started <date>._` and lower the bar for completeness.

---

## 9. Present the draft and ask for additions

Present the drafted monthly review and ask:

> "This is the draft. Anything to add, change, or push back on? Especially: career highlights worth raising, struggles I missed, themes I weighted wrong, or goals where I assessed status incorrectly?"

Incorporate their feedback into the draft.

---

## 10. Write the final note

Write to: `Areas/Career Development/Monthly Reviews/<YYYY>/<YYYY-MM-MMMM>.md`

Full path: `$VAULT/Areas/Career Development/Monthly Reviews/<YYYY>/<YYYY-MM-MMMM>.md`

Example: `…/Monthly Reviews/2026/2026-04-April.md`

Create the directory if needed (Write tool handles this automatically).

---

## 11. Append Career Highlights to the Brag Doc

Append the just-written month's Career Highlights to the Brag Doc. The Brag Doc is the long-running, append-only record of trajectory-relevant work.

Path: `Areas/Career Development/Brag Doc/<YYYY>.md`

If the file does not exist, create it with this header:

```markdown
---
created: <today's date>
year: <YYYY>
---
tags:: [[+Brag Doc]]

# Brag Doc — <YYYY>

> Append-only record of career-trajectory-relevant work. Auto-populated from `/monthly` Career Highlights. Use this as raw material for self-reviews, growth conversations, and 1:1 prep.
```

Then append a section for this month:

```markdown

## <Month> <YYYY>

<Career Highlights bullets, copied verbatim>

— from [[<YYYY-MM-MMMM>|Monthly Review]]
```

If a section for this month already exists in the Brag Doc (re-running `/monthly` for the same month), **replace** that section rather than duplicating it.

---

## 12. Confirm

Report where the note was written. Mention which weeks were synthesized, whether the Brag Doc was created or appended to, and flag anything that felt thin in the underlying data.
