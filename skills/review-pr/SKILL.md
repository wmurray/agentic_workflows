---
name: review-pr
description: Review a teammate's open GitHub PR and produce a compare-notes report you can hold up against your own manual review. Fetches the PR with its intent (description + linked ticket), reviews the diff inline through the right language reviewer's rubric, and leads with a prioritized terminal summary (blocking / should-fix / nit / question) — then walks through findings conversationally. Advisory only: NEVER posts to GitHub. Use for the "can you take a look at this PR? <url>" workflow.
---

# Review PR

Your most common review workflow: you review a teammate's PR **manually** while I review it in parallel, then we **compare notes** and I walk you through what I found. This skill produces my half of that — a findings report structured for comparison, not a viewer dump and not a posted review.

**Advisory only.** This skill NEVER posts comments, approves, requests changes, or otherwise touches the PR on GitHub. You write and post your own review by hand. My job ends at surfacing findings and talking through them.

`$ARGUMENTS` is the PR — a full GitHub URL (e.g. `https://github.com/<your-org>/<repo>/pull/NNN`) or, if the repo is unambiguous from context, a bare number.

---

## 1. Resolve the target

Determine the **repo** and **number** from `$ARGUMENTS`:
- Full URL → parse `owner/repo` and the PR number. `cd $SOURCE_DIR/<repo>` (the local checkout name matches the GitHub repo name).
- Bare number → only valid if the repo is unambiguous from context; if not, ask which repo before proceeding.

All `gh` calls below run from inside `$SOURCE_DIR/<repo>` (or pass the full URL — `gh pr view <url>` works from anywhere).

## 2. Fetch the PR *with its intent*

Review against what the PR claims to do, not just the raw diff.

```bash
cd $SOURCE_DIR/<repo>
gh pr view <n> --json number,title,body,author,url,additions,deletions,changedFiles,baseRefName,headRefName,isDraft,reviewDecision,statusCheckRollup,files \
  --jq '{number,title,author:.author.login,url,isDraft,reviewDecision,
         ci:([.statusCheckRollup[]?|select((.conclusion//.state)=="FAILURE")]|length),
         additions,deletions,changedFiles,
         paths:[.files[].path], body}'
gh pr diff <n>
```

From the `body`, extract any **linked ticket** (e.g. `PROJ-1234`). If one is present and the body is thin, pull the ticket for the real acceptance criteria:
```bash
jira issue view <TICKET> --plain 2>/dev/null
```
This gives the *intended behavior* — review the diff against it (does it do what the ticket asked? miss an acceptance criterion? overreach scope?).

For any changed file where the diff alone is ambiguous, read the **surrounding code** in the checkout (`git -C $SOURCE_DIR/<repo> show <headRefName>:<path>` or just open the file on the branch) — review the change in context, not as an isolated hunk.

## 3. Pick the reviewing lens

Apply the rubric of the language reviewer that matches the repo — **read its rules and apply them inline** (do NOT spawn it as a subagent; reviewing inline keeps the findings in context for walking through them and fielding follow-ups live):

| Repo type | Read & apply | Plus |
|-----------|--------------|------|
| Ruby on Rails | `~/.claude/agents/rails-code-reviewer.md` | repo `AGENTS.md` / `CLAUDE.md` |
| TypeScript/React | `~/.claude/agents/typescript-reviewer.md` | repo `CLAUDE.md` / `AGENTS.md` |
| Go | `~/.claude/agents/go-code-reviewer.md` | repo `CLAUDE.md` / `AGENTS.md` |
| Other | _(no reviewer agent yet — apply general correctness, conventions, and test coverage principles)_ | repo `CLAUDE.md` / `AGENTS.md` |

Always read the target repo's `CLAUDE.md` (or `AGENTS.md`) for its conventions, pack boundaries, and test style — a finding that contradicts a documented convention is wrong, and one that *enforces* a convention is high-value.

## 4. Review

Work through the diff against three axes:
- **Intent** — does it do what the PR/ticket says, completely, without unrequested scope creep?
- **Correctness** — bugs, edge cases, N+1s, error handling, missing/weak tests, security (authz, injection, secrets, supply chain on new deps).
- **Conventions** — alignment with the repo's `CLAUDE.md` / `AGENTS.md` rubric and the reviewer-agent rules from step 3.

Hold findings to a real bar. A 🔴 must be something that should block merge; don't inflate nits. If the PR is clean, say so plainly — "nothing blocking, two nits" is a perfectly good result.

## 5. Compare-notes report (terminal — lead with this)

Print to the terminal. Structure it so you can lay it next to your own read instantly:

```
🔍 PR REVIEW — <repo> #<n>: <title>  (by <author>)
   <link>  · +<adds>/−<dels> across <n> files · CI <green|RED> · <TICKET if linked>

What it does: <one or two lines — my read of the intent, so you can confirm it matches yours>

🔴 Blocking (<n>)
  • <file:line> — <issue> → <suggested fix>
🟡 Should fix (<n>)
  • <file:line> — <issue> → <suggestion>
🔵 Nits (<n>)
  • <file:line> — <minor>
❓ Questions (<n>)
  • <file:line> — <what's unclear / what I'd ask the author>
🔎 Ruled out (<n>)
  • <what looked suspicious> — <why it actually checks out>
```

Rules:
- **Lead with the verdict.** First line after the header is my overall read (intent + a one-line "looks solid / has a blocker / I'd hold on X").
- Bullets, not prose. `file:line` on every finding so we can both jump to it.
- **Omit empty buckets** entirely.
- Sort within a bucket by importance.
- Severity is honest: 🔴 = should block, 🟡 = worth fixing before merge, 🔵 = optional polish, ❓ = I need author intent, not a defect.
- **🔎 Ruled out** captures things that *looked* like findings but check out — a suspicious factory trait that's an established pattern, an apparent N+1 that hits the association cache, a test that looks weak but genuinely exercises the path. Including these saves re-investigating what was already cleared and shows the review went past surface pattern-matching. Only list ones a careful reviewer would plausibly flag — not trivia. Omit the bucket if there were none.
- Flag the **intent line** prominently — if my read of what the PR does diverges from the ticket, that mismatch is itself a finding.

## 6. Compare notes & walk through (conversational)

After the report, hand back:

> "That's my pass — how does it line up with what you found? Happy to dig into any of these."

Then:
- **Walk through** any finding asked about — show the code, explain the reasoning, propose the concrete change.
- **Reconcile**: if something was caught that I missed, treat that as signal — look again at why I missed it. If I flagged something that's disputed, re-examine rather than defend.
- **Offer difit** (only if wanted): load findings as inline `--comment` threads via `npx difit`. Don't auto-launch it.
- **Never post to GitHub.** If help is needed wording a review, draft text to copy — but the user posts it.

---

## Notes for future evolution
- If a repo's reviewer rubric drifts from reality, fix the agent file (step 3) — this skill reads it, so the fix propagates here automatically.
- Possible add: a "diff of reviews" mode — after you paste what *you* found, explicitly diff your list against mine (what we both caught / only you caught / only I caught) to sharpen both over time.
- Keep it advisory. The value is the compare-notes conversation, not automating the review submission.
