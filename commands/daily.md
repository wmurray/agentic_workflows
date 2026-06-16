Complete your daily Obsidian work journal note. Work through these steps precisely.

<!-- Note structure adapted from https://dannb.org/blog/2022/obsidian-daily-note-template/ -->

**Vault:** `$VAULT`

---

## 1. Calculate today's paths

```bash
echo "today_rel=Daily Notes/$(date +%Y)/$(date +%m-%B)/$(date +%Y-%m-%d-%A).md"
echo "yesterday_rel=Daily Notes/$(date -v-1d +%Y)/$(date -v-1d +%m-%B)/$(date -v-1d +%Y-%m-%d-%A).md"
echo "display=$(date '+%A, %B %-d, %Y')"
echo "created=$(date '+%Y-%m-%d %H:%M')"
echo "yesterday_link=$(date -v-1d +%Y-%m-%d-%A)"
echo "tomorrow_link=$(date -v+1d +%Y-%m-%d-%A)"
```

The full path for any relative path is: `$VAULT/<relative>`.

---

## 2. Check if today's note exists

Read the full path for today's note. If it already exists, skip to step 4 and read it now. If it does not exist, proceed to step 3.

---

## 3. Create the note (only if it doesn't exist)

Write the note to the full path, substituting today's calculated values. Use this exact template:

```
---
created: <created>
---
tags:: [[+Daily Notes]]

# <display>

<< [[<yesterday_link>]] | [[<tomorrow_link>]] >>

---
### 📅 Daily Questions
##### 🌜 Yesterday, I
- 

##### 🚀 One+ thing I plan to accomplish today is...
- [ ] 

##### 👎 One thing I'm struggling with today is...
- 

---
# 📝 Notes
- 

---
### Notes created today
```dataview
LIST FROM "" WHERE file.cday = date(today) SORT file.ctime asc
```

### Notes last touched today
```dataview
LIST FROM "" WHERE file.mday = date(today) SORT file.mtime asc
```
```

---

## 4. Read yesterday's note

Read the full path for yesterday's note. Extract:
- The "🌜 Yesterday, I" bullets (what was done yesterday)
- The "🚀 One+ thing I plan to accomplish today is..." checkboxes — these represent what was *planned* to do, which is the starting point for today's "Yesterday, I" section

If yesterday's note doesn't exist, skip this step.

---

## 5. Promote from the Task Backlog

Read `$BACKLOG_FILE` and edit it directly (this step *writes* to the file, so read it fresh rather than relying on the gatherer's read-only `backlog` field).

**🗓 Scheduled — pull due items:**
Extract items dated **≤ today** (`[YYYY-MM-DD]`). Include them in today's plan, then **remove** them from the Scheduled section. (Dated-before-today items are overdue — pull them too; they shouldn't strand.)

**🔁 Recurring — spawn due instances:**
For each `- [ ] [every: <cadence>] description (last: YYYY-MM-DD)`, decide if it's due today:
- `daily` → due if `last` < today
- `weekly` → due if ≥ 7 days since `last`
- `monthly` → due if the month changed since `last`
- a weekday (`mon`–`sun`) → due if today is that weekday and `last` ≠ today

If due, add the task to today's plan and update its `(last: <today>)` in place. Do **not** remove recurring items.

**🔥 Warm — offer (don't force):**
If 1–2 🔥 Warm items have gone cold (`since` > 3 days ago), mention them as optional candidates when presenting the plan in Step 8 — but only pull them in if you pick them up. Don't auto-add.

---

## 6. Gather context

Pull git / PRs / Jira / calendar in one call via the shared gatherer (single source of truth across `/daily`, `/eod`, `/sitrep`). Use a 2-day window so yesterday's work is captured — but **on Monday reach back over the weekend to Friday** (to catch Friday's merges/commits):

```bash
if [ "$(date +%u)" = "1" ]; then WIN="3 days ago"; DAYS=3; else WIN="2 days ago"; DAYS=2; fi
~/.claude/lib/workspace-context.sh --since "$WIN" --jira-days "$DAYS" --recent-days "$DAYS"
```

It returns one JSON object. For drafting the note, read:
- `prs_recent` — `[{repo, number, title, url, state, createdAt, updatedAt, mergedAt}]` — PRs **merged/opened in the window** are the backbone of "Yesterday, I". Filter `mergedAt` within the last ~1–2 days for "merged", recent `createdAt` for "opened".
- `git` — `[{repo, line}]` commits in the window (corroborates what got done).
- `jira_recent` — `[{key, status, summary}]` tickets updated recently; a ticket now `Done`/`Code Review` corroborates completion.
- `jira_open` — `[{key, status, summary}]` open tickets → candidates for today's plan.
- `prs_authored` — `[{repo, number, title, url, isDraft, reviewDecision, updatedAt, staleDays, bumpedDaysAgo, bumpNote, ci}]` your open PRs needing attention (CI red, changes requested, ready to merge). `staleDays` = **working** days untouched; a non-draft PR with `staleDays >= 2` and no fresh bump (`bumpedDaysAgo` null or ≥ 1) is **slipping** — surface it in today's plan (see Step 7).
- `prs_review_direct` / `prs_review_team` — PRs awaiting your review → plan candidates (direct first).
- `calendar` — `["..."]` today's events (include only those needing active participation).


**ICM — agent team and decision context (optional):**
If the `icm_memory_recall` MCP tool is available, use it with the query "work completed tickets PRs today yesterday" to surface anything the agent team (or other sessions) recorded. This catches work done via `/implement` in separate sessions that won't appear in git log or GitHub queries (e.g. tickets completed by the agent team, decisions made, errors resolved).

---

## 7. Draft the note sections

Using all gathered context, synthesize the following sections. Be concise — bullets, not paragraphs.

**"🌜 Yesterday, I":**
Start with yesterday's planned checkboxes. For each one, note whether it appears to have been completed (based on GitHub, git, or issue tracker evidence). Add any significant work not covered by the plan (PRs merged, tickets closed, etc.). Use past tense, active voice. Link all ticket and PR references (see linking rule below).

**"🚀 One+ thing I plan to accomplish today is...":**
Based on open/in-progress tickets, PRs needing attention (review, merge, or fixes), inbox items due today, and any $ARGUMENTS provided. Format as `- [ ]` checkboxes. Keep to 3–5 focused items. Only include specific, actionable items — never generic placeholders like "start next ticket" without naming the ticket.

**Slipping PRs:** include any of your own **stale** PRs (`prs_authored` with `staleDays >= 2`, not draft, not freshly bumped — `bumpedDaysAgo` null or ≥ 1) as an explicit plan item — e.g. `- [ ] Bump/merge [PR #N](url) — Nwd untouched`. The point is to make a slipping PR a visible to-do rather than letting it drift. If you've already nudged one in Slack, record it with `~/.claude/lib/pr-bump.sh <Repo>#<Number> "..."` (suppresses it until the next working day) and drop it from the plan.

Order by priority — highest priority item first. Do not include calendar reminders or non-actionable events. Only include meetings/events that require your active participation.

**Linking rule:** Link all ticket references in your tracker's URL format (Jira example: `[PROJ-123]($JIRA_BASE_URL/browse/PROJ-123)`). Link PR references as `[PR #N](url)` using the URL from the GitHub query.

**"👎 One thing I'm struggling with today is...":** Leave blank — fill in yourself.

**"📝 Notes":** Leave blank.

---

## 8. Present the draft and ask for additions

Present the drafted "Yesterday, I" and "plan for today" sections. Then ask:

> "Anything else to add? Meetings, research, design discussions, code reviews, or anything not captured above?"

Incorporate any additions into the appropriate section.

---

## 9. Write the final note

Write the complete note to the vault at today's full path.

**If the file already existed:** Update only the "Yesterday, I" and "plan for today" sections if they were empty. Do NOT overwrite any content already written. Preserve everything.

**If the file was just created in step 3:** Write the full populated version.
