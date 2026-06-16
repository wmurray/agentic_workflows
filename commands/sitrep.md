A fast 30,000-foot situation report — a mid-day re-orientation tool. Answers "where am I at, am I on the main storyline, and what's the one next thing?" Read-only by default: it gathers and synthesizes, it does NOT modify notes unless explicitly asked at the end.

**Vault:** `$VAULT`

Design intent: the risk is twofold — (1) drifting onto a satisfying sidequest while the priority stalls, and (2) small captured tasks silently slipping away. This report counters both. **End with the answer** — the evidence sections are skimmable context, and the VERDICT + NEXT action block is printed **last**, in a rule-boxed footer, because a terminal scrolls to the bottom and that's where your eyes rest when the output stops. The action must never scroll off-screen above the fold.

---

## 1. Calculate paths

```bash
echo "today_rel=Daily Notes/$(date +%Y)/$(date +%m-%B)/$(date +%Y-%m-%d-%A).md"
echo "yest_rel=Daily Notes/$(date -v-1d +%Y)/$(date -v-1d +%m-%B)/$(date -v-1d +%Y-%m-%d-%A).md"
echo "d2_rel=Daily Notes/$(date -v-2d +%Y)/$(date -v-2d +%m-%B)/$(date -v-2d +%Y-%m-%d-%A).md"
echo "today=$(date +%Y-%m-%d)"
echo "now=$(date '+%-I:%M %p')"
```

The full path for any relative path is `$VAULT/<relative>`.

---

## 2. Read today's plan (the storyline)

Read today's note. Extract from the "🚀 One+ thing I plan to accomplish today is..." section:
- Checked items `[x]` — already done
- Unchecked items `[ ]` — the **declared priorities** (the "main storyline")

Also skim the "📝 Notes" section for anything actionable jotted mid-day.

If today's note doesn't exist, the report MUST show a banner line `⚠ No /daily note yet — run /daily to lock today's plan` directly under the title at the top, then continue using live context only (skip the drift comparison — there's no declared plan to compare against), and set the footer VERDICT to `re-orienting — no plan set`. Do not bury this; an unset plan is itself a re-orientation signal.

---

## 3. Gather live context (run in parallel)

Pull every stream in one call via the shared gatherer — it's the single source of truth for `/daily`, `/eod`, and `/sitrep` (so a query fix lands in one place):

```bash
~/.claude/lib/workspace-context.sh
```

It returns one JSON object. Read these fields:
- `git` — `[{repo, line}]` commits **today** (the reality check for drift). Empty = nothing committed yet.
- `prs_authored` — `[{repo, number, title, url, isDraft, reviewDecision, updatedAt, staleDays, bumpedDaysAgo, bumpNote, ci}]` your open PRs. `ci` ∈ `passing|failing|pending|none`. Use `isDraft` + `reviewDecision` (`CHANGES_REQUESTED`/`APPROVED`/`REVIEW_REQUIRED`) + `ci` to label state. `staleDays` = **working** days untouched (weekends excluded). `bumpedDaysAgo`/`bumpNote` = an out-of-band Slack bump logged (null if none).
- `prs_review_direct` — `[{repo, number, title, url, author, createdAt}]` PRs requested of you **personally**, oldest first. Highest review priority — you're the named reviewer, nobody else covers.
- `prs_review_team` — same shape, requested of the `$GH_TEAM` team (already deduped against direct). Lower priority — coverable by others.
- `jira_open` — `[{key, status, summary}]` your tickets where `statusCategory != Done`.
- `calendar` — `["..."]` today's timed events.
- `backlog` — raw Task Backlog markdown with tier sections (📥 Triage, 🗓 Scheduled, 🔁 Recurring, 🔥 Warm, ❄️ Cool, 🧊 On ice). Parsed in Step 4.

**Age + staleness (reviews waiting on you):** compute each review's age from `createdAt` vs `today`. Flag any ask older than ~3 business days as stale (⚠) — every stale review is a prompt-feedback slip (standing objective), direct ones most acutely.

**Stale PRs (your own, slipping):** from `prs_authored`, flag a PR as stale when **`staleDays >= 2` AND `isDraft == false`** AND it isn't freshly bumped (**`bumpedDaysAgo` is null OR `bumpedDaysAgo >= 1`**). These are PRs that have gone quiet — needing a rebase, a reviewer ping, a merge, or a CI fix. A same-day Slack bump (`bumpedDaysAgo == 0`, with `bumpNote`) means it's already been nudged out-of-band → suppress it for that day (optionally note "✓ bumped today" so it's tracked); it re-surfaces the next working day if still unanswered. Drafts are intentional WIP — never flag them.

**ICM — cross-session agent work (optional):**
If the `icm_memory_recall` MCP tool is available, use it with query "work in progress tickets PRs decisions today" to surface anything the agent team or other sessions recorded that won't appear in local git/GitHub.

---

## 4. Loose-ends sweep (the slippage hunt)

This is the part `/daily` and `/eod` don't cover. Find tasks at risk of vanishing:

Parse the `backlog` field returned by the gatherer in Step 3 (no need to re-read the file). It has tier sections — handle each:

**a) 🗓 Scheduled — overdue / due / imminent:**
Items are `- [ ] [YYYY-MM-DD] Description`. Classify against today's date:
- **Overdue** — dated *before* today, still unchecked (silent slips — `/daily` only pulls items dated ≤ today *on the morning it runs*, so a missed day strands them). Flag prominently.
- **Due today** — dated today but not yet in today's plan.
- **Imminent** — dated within the next 2 days (heads-up only).

**b) 🔥 Warm — gone cold:**
Items are `- [ ] Description (since: YYYY-MM-DD)`. Surface any whose `since` is **> 3 days** before today — these are things you wanted kept top-of-mind that have quietly stalled. (Items within 3 days are still "warm enough" — don't nag.)

**c) ❄️ Cool — only if asked or streams are quiet:**
Do **not** list Cool items by default. If the streams show a genuine lull (no stale reviews, no overdue/due items, nothing mid-flight) OR you ask for "a quick thing", offer 1–3 ❄️ Cool items, filtered by any effort qualifier ("got 15 min"). Items are `- [ ] [~15m|~30m|~1h] Description`.

**d) Orphaned todos from recent notes:**
Read yesterday's and the day-before's notes (paths from Step 1). Collect unchecked `[ ]` items from their "plan for today" sections that do **not** appear (done or open) in today's plan, and aren't already captured in a backlog tier. These rolled off without being finished, carried forward, or demoted — prime candidates to capture into 🔥 Warm / 🗓 Scheduled (offer in Step 6).

---

## 5. Synthesize the report

Output to the terminal (do not write to any file). Structure it lead-with-the-answer:

```
🧭 SITREP — <now>
<⚠ banner line here ONLY if today's note is missing — see Step 2>

— Main storyline ———————————————
Planned today:  <priority items, ✓ done / ◦ open>
Actually doing: <what git/PRs show, today>
<If these diverge, say so plainly: "You're deep in <sidequest>; <priority> hasn't moved.">

— Streams —————————————————————
My PRs:        <#N title — state (draft / changes-requested / CI red / ready-to-merge)>
Stale PRs:     <#N title — Nwd untouched (CI/review state) — bump, rebase, or merge>
Review (direct, on you): <#N title by author — age, oldest first; ⚠ if stale>
Review (team): <N PRs for $GH_TEAM (oldest #M, X days) — "expand" or qualify e.g. "oldest">
In progress:   <PROJ-XXXX title>
Up next (tickets): <top To Do ticket(s)>

— Loose ends at risk ——————————
⚠ Overdue:    <🗓 scheduled dated before today>
• Due today:  <🗓 scheduled for today not yet planned>
🔥 Gone cold: <🔥 warm items untouched > 3 days>
↩ Rolled off: <orphaned unchecked todos from recent notes>
~ Imminent:   <next-2-day 🗓 scheduled>
<❄️ Cool quick-wins line ONLY if streams are quiet or you asked>

— Time ————————————————————————
<remaining meetings today, if any>

═══════════════════════════════════════
VERDICT: <on-track | drifting | re-orienting>
👉 NEXT:  <adaptive — a single named action; OR the DECIDE block below>
  # one action clearly dominates → name just it:
  👉 NEXT:  <the single highest-impact concrete action, named specifically>
  # two+ genuinely compete → present the call instead of forcing a winner:
  DECIDE (your call):
    ⏰ Hard deadlines:         <item — when due — link>
    🔓 Blockers you can clear: <review [PR #N] / answer X / feedback to Y — who/what it unblocks — link>
    <other lane only if a third genuinely competes>
═══════════════════════════════════════
```

This action footer is the **last thing printed** — nothing comes after the closing rule line.

Rules:
- **The action footer is printed last.** The rule-boxed `VERDICT` + `NEXT`/`DECIDE` block ends the *report* — no report section comes after the closing `═` line. This is deliberate: the terminal scrolls to the bottom, so the action is what's on screen when reading stops. The two `═` rule lines (top and bottom) make it unmissable — keep them. The only thing that may follow the footer is the **single-line** capture offer from Step 6 — keep it to one line so the boxed action stays the visual anchor.
- **Be ruthless about brevity.** Bullets, not prose. If a section is empty, omit it entirely rather than printing "none." The shorter the evidence above, the less the footer has to compete with — but the footer is bottom-anchored regardless.
- **Link refs:** tickets in your tracker's URL format (Jira example: `[PROJ-123]($JIRA_BASE_URL/browse/PROJ-123)`), PRs `[PR #N](url)`.
- **Reviews: direct expanded, team collapsed.** List every DIRECT review request in full (with author + age, oldest first, ⚠ stale). Collapse TEAM requests to a one-line count noting the oldest (`N PRs for $GH_TEAM, oldest #M @ X days`) and invite the user to say "expand" or a qualifier ("oldest", or a specific repo) to pull the full list — don't print all team PRs unprompted.
- **The drift call must be honest.** If today's commits/PRs are all on something other than the stated top priority, say it directly — that's the whole point of the tool. Don't soften it into invisibility.
- **NEXT is adaptive, not always singular.** You have fuller context than the AI on what matters *right now*, so don't fake certainty when categories genuinely compete:
  - When one action clearly dominates (a single hard deadline, or an obvious top priority with nothing rivaling it), name **just that one** — don't manufacture a decision menu.
  - When two or more genuinely compete (e.g. a hard external deadline *and* a pile of teammate-blocking reviews), present a `DECIDE` block grouped by **impact lane** — `⏰ Hard deadlines` (external, time-bound, unrecoverable if missed) and `🔓 Blockers you can clear` (a review, an answer, feedback/context/research someone is waiting on) are the two primary lanes; add a third only if it truly rivals them.
  - **Trim ruthlessly.** Max ~2 candidates per lane, only the genuinely highest-impact ones. The job is to narrow the field to a few high-leverage choices, not to list everything open. Noise defeats the purpose.
  - Every candidate must be feasible given remaining meeting time, and named concretely (linked PR/ticket + a few-word what/why), never "review some PRs."

---

## 6. Offer to capture (only if asked)

End with a single offer — do not act on it unless confirmed:

> "Want me to capture any of these — re-date an overdue 🗓, cool a rolled-off todo to 🔥/❄️, add something to today's plan?"

If confirmed, update the Task Backlog (`$BACKLOG_FILE`) under the right tier section and/or today's note, preserving all existing content. When demoting a rolled-off todo, default to 🔥 Warm with `(since: <today>)` unless specified otherwise. Never modify notes without explicit confirmation.

**Stale-PR follow-ups:** if a stale PR was listed and you've already nudged it out-of-band (e.g. "I pinged the reviewer in Slack"), record it so it stops surfacing until the next working day:
```bash
~/.claude/lib/pr-bump.sh <Repo>#<Number> "pinged <who> in Slack"
```
(GitHub can't see a Slack ping, so without this it'd keep flagging.) If a flagged PR has actually been merged/closed, clear any stale follow-up with `~/.claude/lib/pr-bump.sh --clear <Repo>#<Number>`. Only run these on explicit say-so.

---

## Notes for future evolution

- **Phase 2 (scheduled nudge):** a recurring trigger (e.g. mid-morning + post-lunch) that runs this report and, if drift or overdue loose ends are detected, fires a macOS desktop notification (`osascript -e 'display notification ...'`) rather than opening a terminal window. Build only after the report content is trusted.
- **Shared plumbing:** Steps 3–4 are the same data streams `/daily` and `/eod` use. If those streams change (new repo, issue tracker project, inbox location), update all three.
