Update today's existing Obsidian daily note with anything completed since it was last written. This is an end-of-day update — do NOT recreate the note or overwrite existing content.

**Vault:** `$VAULT`

---

## 1. Read today's note

```bash
echo "today=Daily Notes/$(date +%Y)/$(date +%m-%B)/$(date +%Y-%m-%d-%A).md"
```

Read the full path. If it doesn't exist, stop — run `/daily` instead.

---

## 2. Check what's already recorded

Read the current "🚀 plan for today" section and note which items are already checked off (`[x]`) and which are still open (`[ ]`).

---

## 3. Gather fresh context (since the note was last written)

Pull today's git / PRs / issue tracker data in one call via the shared gatherer (single source of truth across `/daily`, `/eod`, `/sitrep`):

```bash
~/.claude/lib/workspace-context.sh --since "today" --jira-days 1
```

From the returned JSON, read:
- `prs_recent` — `[{repo, number, title, url, state, createdAt, updatedAt, mergedAt}]` — PRs **merged or updated today** (filter `mergedAt`/`updatedAt` to today) are the main "what got done since this morning" signal.
- `git` — `[{repo, line}]` commits today.
- `jira_recent` — `[{key, status, summary}]` tickets touched in the last day; a status now `Done`/`Code Review` corroborates completion.
- `prs_authored` — `[{repo, number, title, url, isDraft, reviewDecision, updatedAt, staleDays, bumpedDaysAgo, bumpNote, ci}]` for any of today's open-PR state changes worth noting, and for the stale-PR check in Step 5. `staleDays` = **working** days untouched.

**ICM — anything the agent team completed today (optional):**
If the `icm_memory_recall` MCP tool is available, use it with query "work completed tickets PRs today" to surface agent-team sessions from today.

---

## 4. Identify gaps

Compare the fresh context against what's already in the note. Find:
- Open `[ ]` checkboxes that now appear to be done → mark as `[x]`
- Work completed that isn't on the list at all → add as new `[x]` bullets
- Anything worth noting in the 📝 Notes section

---

## 5. Ask for anything else (+ bump slipping PRs before logging off)

> "Anything else to add before wrapping up today? Meetings, conversations, blockers, or anything not in git/GitHub/your issue tracker?"

**Stale-PR check:** scan `prs_authored` for any non-draft PR with `staleDays >= 2` that isn't freshly bumped (`bumpedDaysAgo` null or ≥ 1). End-of-day is the moment to act before it slips another day — surface them briefly:

> "Before you log off — [PR #N](url) has sat Nwd untouched. Bump it, or want me to note you've nudged it?"

If already pinged out-of-band (Slack, etc.), record it: `~/.claude/lib/pr-bump.sh <Repo>#<Number> "..."` (suppresses the nudge until the next working day). If it's actually merged/closed, `~/.claude/lib/pr-bump.sh --clear <Repo>#<Number>`. Don't run these unprompted.

---

## 6. Update the note

Edit only the changed sections in place. Preserve everything already written. Link all ticket and PR references:
- Tickets: use your tracker's URL format (Jira example: `[PROJ-123]($JIRA_BASE_URL/browse/PROJ-123)`)
- PRs: `[PR #N](url)`

---

## 7. Demote unfinished work (the slippage gate)

This is the step that stops tasks from rotting silently. After the note is updated, look at today's plan for items **still unchecked** (`[ ]` / `[~]`). For each one, don't just leave it — ask where it should go. Present them as a short list with a recommended destination each, e.g.:

> "These didn't get finished today — where should each land?
>  • PROJ-1472 Pairing session → reschedule 🗓 (needs a 2nd person — pick a day?)
>  • Review #6154 → 🔥 Warm (in progress, resume soon)
>  • Add bin/doctor note → ❄️ Cool (~15m, whenever)"

Destinations (write to `$BACKLOG_FILE`, preserving existing content):
- **🗓 Scheduled** — `- [ ] [YYYY-MM-DD] …` for a specific day
- **🔁 Recurring** — if it should repeat
- **🔥 Warm** — `- [ ] … (since: <today>)` to keep top-of-mind without a date
- **❄️ Cool** — `- [ ] [~Xm] …` quick-win pool
- **🧊 On ice** — `- [ ] … — parked: <reason>`
- **Drop** — if it no longer matters

Also sweep the backlog's **📥 Triage** section: if anything was dumped there today, offer to sort each into a tier. Only write what is confirmed — never silently re-file.
