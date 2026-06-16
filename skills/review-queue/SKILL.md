---
name: review-queue
description: Work a batch of teammate PRs in one sitting — review several at once and walk them one at a time through difit. Reviews the first PR inline, fans the rest out as background reviews (so the next one is always ready), then opens each in difit for inline comments, discusses it to completion, and advances only on your say-so. Default (no args) takes the 3 oldest PRs awaiting review across your team; an explicit list (`/review-queue 123 456 …` or URLs) reviews exactly those in order. Advisory only — NEVER posts to GitHub. Builds on the review-pr skill; pairs with /review-radar (the team-wide monitor) for handoff.
---

# Review Queue

A batch front-end to the `review-pr` workflow, built for a **review sitting**: sit down to clear several PRs at once. The trick is that you can only look at one diff at a time, so this skill **pre-computes reviews in parallel in the background** while you work the front of the queue — the next PR's difit always opens instantly, never with a wait.

Two halves, kept strictly separate:
- **Compute fans out.** PRs after the first are reviewed by background agents that write a report + a `findings.json` each.
- **Consumption is serial and human-gated.** You walk one PR at a time through difit, discuss it to completion, and **only advance when you say so**. Closing difit never auto-jumps to the next PR.

**Advisory only.** Like `review-pr`, this NEVER posts comments, approves, or requests changes on GitHub. The only GitHub access is *reading* (PR metadata, diff, ticket). All output is local: difit threads + markdown reports you read. You write and post your own reviews by hand.

`$ARGUMENTS`: empty, or an ordered list of PRs (bare numbers, `Repo#123`, or full URLs).

---

## 1. Build the queue

**No args (default):** take the 3 oldest PRs awaiting review across your team — your direct asks *and* team-requested PRs, merged.
```bash
bash ~/.claude/lib/workspace-context.sh | jq -c '
  (.prs_review_direct | map(. + {direct:true}))
  + (.prs_review_team | map(. + {direct:false}))
  | sort_by(.createdAt) | .[:3]'
```
- `prs_review_direct` = `user-review-requested:@me` — PRs where you are *individually* requested.
- `prs_review_team` = `team-review-requested:$GH_TEAM` (set in `lib/workspace-context.sh`), already deduped against direct in the helper.
- Merge the two, sort **oldest-created first**, take the first **3**. Each entry: `{repo, number, title, url, author, createdAt, direct}`. Keep the `direct` flag — it drives the `← you` marker in the queue print so you can see at a glance which are your own asks vs. the team's.

> **Config — buckets.** Default is the merged team queue (direct + team). To narrow back to *only* your direct asks, read `.prs_review_direct[:3]` alone. For the full team picture (every stuck PR, not just the oldest 3, including individual-reviewer requests outside the team), use the **`/review-radar`** skill — it's the team-wide monitor and hands a chosen subset back here.

**Explicit list:** review exactly what's passed, **in the given order** (this *is* the batch size — no cap).
- Full URL → parse `owner/repo` + number.
- `Repo#123` → that repo, that number.
- **Bare numbers** are ambiguous across repos. If the terminal cwd is inside one checkout (`$SOURCE_DIR/<repo>`), assume that repo for all of them and say which you assumed. Otherwise ask once which repo the list belongs to before proceeding.
- If the explicit list has **> 5** PRs, print a one-line heads-up that N parallel reviews is a meaningful chunk of tokens, then proceed (don't block).

**Print the resolved queue and start** — don't ask for confirmation on the default-3 path; just show it and go (you can interrupt):
```
📋 Review sitting — 3 PRs ($GH_TEAM queue, oldest first)
  1. MyApp #5840  <title>            (5d, by alice)   ← you · reviewing now
  2. MyApp #5851  <title>            (3d, by bob)     ⏳ baking in background
  3. MyApp #912   <title>            (1d, by cara)    ⏳ baking in background
```

## 2. Reports directory

All artifacts go here (temporary — see §7):
```
$VAULT/Areas/PR Reviews/
```
Create it on first run if absent. Per PR, two files keyed `<repo>-<number>-<slug>` (slug = kebab-cased title, ~6 words):
- `<repo>-<number>-<slug>.md` — the compare-notes report (human-readable).
- `<repo>-<number>-<slug>.findings.json` — structured findings that feed difit (schema in §4).

## 3. Fan out: review #1 inline, the rest in the background

**Spawn background agents for PRs 2..N — all at once, in a single message** (`run_in_background: true`). Each agent reviews one PR and writes its two files. Concurrency self-caps, so a long list just bakes in waves. Agent prompt, per PR:

> Review GitHub PR **<url>** as an advisory reviewer. Do NOT post anything to GitHub — read only.
> 1. Read and follow `~/.claude/skills/review-pr/SKILL.md` steps 2–4 (fetch the PR with its intent + linked ticket, pick the matching language-reviewer rubric — `rails-code-reviewer.md` for Rails repos, `typescript-reviewer.md` for TypeScript/React repos — read the repo's `AGENTS.md`/`CLAUDE.md`, and review against intent / correctness / conventions).
> 2. Write the compare-notes report to `$VAULT/Areas/PR Reviews/<repo>-<number>-<slug>.md` using review-pr's §5 format (header, verdict, 🔴/🟡/🔵/❓/🔎 buckets, `file:line` on every finding, omit empty buckets).
> 3. Write `$VAULT/Areas/PR Reviews/<repo>-<number>-<slug>.findings.json` matching the schema in review-queue SKILL.md §4 — every line-anchored finding becomes an object, severity preserved.
> Return one line: the verdict and the finding counts. Hold findings to a real bar — don't inflate nits.

**Review PR #1 inline yourself** (in this session, so its findings live in my context and I can discuss them live): run review-pr steps 2–4 on PR #1, then write its `.md` and `.findings.json` exactly as the agents do.

## 4. findings.json schema

```json
{
  "pr": { "repo": "MyApp", "number": 5840, "title": "...", "url": "...",
          "author": "alice", "headRef": "feature-x", "baseRef": "main",
          "ci": "green|red|pending", "ticket": "PROJ-1234|null" },
  "verdict": "one-line overall read",
  "whatItDoes": "1–2 line intent",
  "findings": [
    { "severity": "blocking|should-fix|nit|question|ruled-out",
      "filePath": "app/models/foo.rb",
      "side": "new",                 // "new" = target side, "old" = deleted side
      "line": 102,                   // or a range: { "start": 36, "end": 39 }
      "title": "short label",
      "body": "full explanation → suggested fix" }
  ]
}
```
Only findings with a concrete `filePath` + `line` go in `findings`. General/whole-PR observations live in the `.md` and the verdict line — I raise those verbally, they don't need a difit anchor.

## 5. difit round-trip for the current PR

difit is **blocking** — it serves the diff locally and prints your comments to stdout only when you **close** it. That's the whole interaction: you comment inline (including replying to my preloaded threads), close, then I get everything at once.

Load the current PR's `findings.json` and turn each finding into a difit `--comment` thread. Prefix the body with the severity so it reads at a glance:
```
[🔴 BLOCKING] <title>
<body>
```
(`🔴 blocking`, `🟡 should-fix`, `🔵 nit`, `❓ question`, `🔎 ruled-out`.) Map `severity`→marker, `filePath`→`filePath`, `side`→`position.side`, `line`→`position.line` (scalar or `{start,end}`).

Use `difit` if on PATH, else `npx difit`. Launch from inside the repo so it has the git context:
```bash
cd $SOURCE_DIR/<repo>
# Try the PR URL form first (difit accepts a GitHub PR URL):
npx difit <pr-url> \
  --comment '{"type":"thread","filePath":"app/models/foo.rb","position":{"side":"new","line":102},"body":"[🔴 BLOCKING] …\n…"}' \
  --comment '{"type":"thread","filePath":"app/x.rb","position":{"side":"new","line":{"start":36,"end":39}},"body":"[🟡 should-fix] …"}'
```
If the URL form isn't supported, fall back to fetched refs (non-destructive — no branch switch):
```bash
base=$(gh pr view <num> --json baseRefName -q .baseRefName)
git fetch origin "pull/<num>/head:refs/difit/pr-<num>" "$base" --quiet
npx difit refs/difit/pr-<num> "origin/$base" --comment '…' --comment '…'
```
Never put secrets/tokens from the diff into `--comment` bodies.

When difit exits, its stdout carries your comments (or none). Treat "server shut down with no comments" as "no inline comments — let's talk."

## 6. Discuss to completion, then advance on your word

After difit #1 closes, **stay on PR #1**. Do NOT auto-advance.
- **Address your comments and questions.** My notes were preloaded as threads, so you may have replied "explain this" right on one — answer those, show the code, propose the concrete change.
- **Reconcile** against review-pr §6: if you caught something I missed, look at *why* I missed it; if you dispute a finding, re-examine rather than defend.
- **Optional re-loop:** if a PR is meaty, I can fold my explanations back in as new threads and relaunch difit #1 — `findings.json` makes that cheap, and your earlier comments are already captured.
- **Draft, don't post:** if you want help wording your own GitHub review, draft copy-paste text. You post it.

**Advance only when you say so** ("next", "done with this one"). Then move to PR #2 — its report is already baked, so just load `<…>.findings.json` and go straight to §5. No wait. If a background review for the next PR somehow isn't done yet, say so and wait for it rather than re-reviewing.

Between PRs, a one-line transition is enough:
```
✅ MyApp #5840 — done. Next: MyApp #5851 (already reviewed) — opening in difit.
```

## 7. Wrap up & cleanup

When the queue is exhausted, print a short recap (one line per PR: verdict + whether you left comments).

Reports are **temporary** — they exist for this sitting, not as a record. Offer to clean up:
- **Prune merged/closed:** for each report file, `gh pr view <num> --repo <repo> --json state -q .state`; delete the `.md` + `.findings.json` for any that are `MERGED`/`CLOSED`.
- Leave still-open PRs' reports in place (you may revisit).

Run the prune at the **start** of a run too (cheap), so stale reports from merged PRs don't accumulate — no separate weekly chore needed.

---

## Invariants
- **Advisory only — never touch GitHub.** Read PRs; write difit threads + local reports. Nothing else.
- **Serial consumption, parallel compute.** Never open two difits or auto-advance.
- **Single source of truth.** The review rubric lives in `review-pr` + the reviewer-agent files; this skill orchestrates, it doesn't redefine the bar. If the rubric drifts, fix it there.

## Notes for future evolution
- **Rolling prefetch:** instead of a fixed batch, keep the next 1–2 PRs baked ahead and kick off a new review each time you advance — smoother for deep queues.
- **Notification hook:** when a sitting's background reviews all finish, an `osascript -e 'display notification …'` could ping you. Deferred — add when wanted.
- **Team bucket:** flip in `.prs_review_team` (see §1 config) when the full team queue is wanted.
