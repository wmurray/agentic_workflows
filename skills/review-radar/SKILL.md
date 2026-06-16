---
name: review-radar
description: Team-wide monitor for PRs stuck waiting on review — every open, non-draft PR across your configured repos that has a pending review request (reviewer asked, no review action since the last request), sorted by how long it's been waiting in working days. Flags the ones waiting on you. Advisory only — NEVER posts to GitHub. Closing move offers to hand a chosen subset to /review-queue for a difit walkthrough. Default (no args) reports the whole team; pass --me <login> to re-anchor "waiting on you".
---

# Review Radar

A **monitor**, not a driver. Answers one question: *across your repos, which PRs are sitting unreviewed, and for how long?* It's the team-wide counterpart to `review-queue` — radar tells you **what's stuck**; `review-queue` is how you actually **work** a subset of them through difit.

The signal is exact, not heuristic. GitHub drops a reviewer from a PR's `reviewRequests` the instant they submit a review, and re-adds them on a re-request. So a PR with a **non-empty `reviewRequests` list** is, by definition, *requested + no review action since the last request* — which is precisely what we're hunting. (A PR can carry an old review and still be waiting, if the author re-requested after pushing changes — radar catches that correctly via the re-request timestamp.)

**Advisory only.** Like `review-pr`/`review-queue`, radar reads GitHub and nothing else. It does not post, nudge, approve, or request review. It produces a terminal report; you decide what to do.

`$ARGUMENTS`: empty (report the whole team), or flags forwarded to the helper — `--me <login>` (re-anchor the "waiting on you" flag; defaults to your GitHub login set in `lib/review-radar.sh`), `--repos "A B C"` (narrow the repo set).

---

## 1. Gather

One call does all the work — a single GraphQL query per repo fetches open PRs, their pending reviewers, and the review-request timeline, then computes per-reviewer waiting time in **working days** (Sat/Sun excluded, mirroring `workspace-context.sh`):

```bash
bash ~/.claude/lib/review-radar.sh
```

Forward any `$ARGUMENTS` (e.g. `--me someoneelse`, `--repos "RepoA RepoB"`) straight through. The output JSON shape is documented at the top of that script — the field that matters most is `waiting[]`, already **sorted worst-wait-first**, each entry carrying `pendingReviewers[]` (with `waitingDays`), `maxWaitingDays`, and `waitingOnMe`.

> **Single source of truth.** The query, the working-days math, and the "what counts as stuck" definition all live in `review-radar.sh`. If the signal needs to change (e.g. ignore bot reviewers, add a staleness threshold), fix it **there**, not in this prose.

## 2. Report

The report has two sections, in priority order: **`waiting`** (a reviewer is on the hook — the core signal) then **`unrequested`** (open, not approved, but *nobody* asked to review — the ball is on the author). Close with a one-line `counts` summary so the rest of the open-PR field is accounted for without listing it. Worst wait at the top within each section; mark the ones waiting on you with `← you`, and show each pending reviewer with their own wait so a PR waiting on two people for different lengths is legible.

```
🛰️  Review radar — team-wide

🟢 Waiting on a reviewer (2)
  MyApp #6243  Extract Member responsibilities…   2d   ← you
       <alice> · waiting: <you> 2d
  MyApp #6257  PROJ-850: gate user audience…       1d
       <alice> · waiting: <your-team> 1d

🟡 Open, not approved, no reviewer requested (2)  — ball is on the author
  MyApp  #6074  Scrub event.contexts in Sentry…   22d
       <bob> · REVIEW_REQUIRED, no reviewer assigned
  MyApp  #6255  [PROJ-1510] Move profile queries…  1d   ← yours
       <you> · REVIEW_REQUIRED, no reviewer assigned

   …plus 9 approved (author to merge) · 10 drafts · 86 dependabot
```

Guidelines:
- **Lead with what's actionable for you.** If any `waitingOnMe` PRs exist (in `waiting`), call them out first in a one-line summary ("2 are waiting on you"), since those are yours to clear. If any `unrequested` entries are `mine:true`, flag them too — those are *your* PRs needing a reviewer assigned (your action, not the team's).
- **`unrequested` is "waiting on the author," not "waiting on a reviewer"** — say so plainly so it's never mistaken for the core signal. These have no reviewer on the hook; they need the author to request one (or push fixes). `ageDays` = working days since the PR was opened, a soft staleness cue.
- **The `counts` line is a summary, never a list.** `approvedPendingMerge` / `changesRequested` / `drafts` / `dependabot` are author-side or out-of-lane; reduce them to the one-liner. If `dependabot` is large, nudge toward `/dependabot-triage` rather than enumerating.
- **Working days, stated as such** — "2d" means two working days, so a Friday request reads "0d" on Friday and "1d" Monday. Don't translate to calendar days.
- **Empty is a clean result**, not an error: if both `waiting` and `unrequested` are empty, "🛰️ Nothing stuck — no PRs awaiting review or needing a reviewer across the repos." (still worth printing the `counts` line). Stop there.
- Keep titles to ~40 chars; the PR number + repo is the clickable handle.

## 3. Hand off to /review-queue (the closing move)

Radar's only "action" is to set up an actual review sitting. After the report, offer the handoff — the PRs waiting on **you** are the natural candidates, but you can pick any subset, including `unrequested` ones to review unprompted (review-queue takes any `Repo#number`). PRs that are `mine:true` in `unrequested` are *your own* and need a reviewer assigned — those aren't review-queue fodder; just flag them to action.

> "Want me to open the ones waiting on you in /review-queue? That's `MyApp#6243`."

The interface is just `review-queue`'s explicit-list arg — build it from the chosen entries as `Repo#number` tokens (the report already prints them in that form), preserving radar's worst-wait-first order:

```
/review-queue MyApp#6243 MyApp#6257
```

Then invoke `review-queue` with that list. **Don't auto-launch** — wait for the user to say which (or "all of mine", or "skip it"). Radar surfaces; you choose; review-queue drives. No orchestrator sits between them — this one-line handoff *is* the composition.

---

## Invariants
- **Advisory only — never touch GitHub.** Read PRs; print a report; optionally hand a list to review-queue. Nothing else.
- **Monitor, not driver.** Radar never opens difit, never reviews a diff itself. The moment actual reviewing starts, it hands off to `review-queue` and gets out of the way.
- **The signal lives in the helper.** Core signal `waiting` = non-empty `reviewRequests`; the secondary `unrequested` bucket = open, non-draft, human-authored, not approved, no reviewer requested. Both definitions (and the `counts` reductions) live in `review-radar.sh` only — if they evolve, change them there, not in this prose.

## Notes for future evolution
- **Staleness threshold:** a `--min-days N` filter (drop anything waiting < N working days) for when the team is busy and only the truly-aged matter.
- **Author's own view:** radar is reviewer-centric. A sibling flag could flip it to "PRs *I* authored that are stuck waiting on others" — but that already lives in `prs_authored` via `workspace-context.sh`; surface it there rather than here.
- **Notification hook:** an `osascript` ping when something crosses N days waiting on you. Deferred — add when wanted.
- **Ignore bots/teams:** if team-level requests prove noisy, filter `type=="team"` or known bot logins in the helper's final map.
