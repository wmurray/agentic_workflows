---
name: reply-comments
description: Work the review comments on one of your own open PRs in a single pass. Triages every unresolved thread, fixes the clear items and pushes them to the PR's own branch, then replies in each thread (what changed, an answer, or a decline with its reason). Replies are published through the guarded reply wrapper when REPLY_POST_WRAPPER is set, otherwise left as private pending drafts. Every published answer and decline goes to a spot-check report. Never resolves a thread, marks ready, or merges. Use as /reply-comments <owner/repo> <pr>, for a PR with no mission-control board row.
---

# Reply to review comments on your own PR

The same triage, fix and reply flow the mission-control loop runs in its kickback address
round (loop-driver Prep-write 5), for one PR you name, without a board row. You invoked it, so
it runs to the end without pausing; the guards that make that safe live in the reply wrapper's
code, not in this file.

Arguments passed: $ARGUMENTS

They name the PR as `<owner/repo> <pr>`, `<owner/repo>#<pr>` or a full PR URL, optionally
followed by `--dry-run`. With `--dry-run`, make no commit, no push and no draft: pass
`--dry-run` to every wrapper call and report what would have happened. Anything else in the
arguments: stop and print the usage line `/reply-comments <owner/repo> <pr> [--dry-run]`.

## Configuration

Org values come from env vars in your shell profile, never from this file.

| Var | Default | Used for |
| --- | --- | --- |
| `REPLY_POST_WRAPPER` | empty: draft only | the guarded reply wrapper, e.g. `~/.claude/lib/review-toolkit/review-reply.sh`. Its allowlists live in its own `review.env` |
| `REPLY_DRAFT_WRAPPER` | empty: GitHub's pending-review API (step 6) | a local helper that adds a reply to a thread as a PRIVATE pending review comment, called `reply --repo <r> --pr <n> --thread <id> --body "<text>"` |
| `REPLY_STYLE_GUIDE` | `${WRITING_STYLE_SKILL:-}` | the reply voice: a file path to read, or a skill name to load. It also gives the exact header line a published reply opens with |
| `MC_AUTO_POST_REPORT` | `$MC_HOME/auto-post-report.md` | the spot-check report, shared with the loop |
| `MC_HOME` | `$HOME/.claude/mission-control` | the mission-control runtime dir (work log, board) |
| `SOURCE_DIR` | `$HOME/Projects` | root folder holding your repo checkouts |
| `MC_GATE1_PATH_DENY` | empty | paths a fix must never touch without you; an item whose fix touches one is held |

Write each as `${VAR:-default}` in commands, e.g. `${REPLY_POST_WRAPPER:-}` and
`${MC_AUTO_POST_REPORT:-${MC_HOME:-$HOME/.claude/mission-control}/auto-post-report.md}`.

**Publishing or drafting.** Publish only when `${REPLY_POST_WRAPPER:-}` is non-empty and
executable. Otherwise every reply is a private pending draft, and judgment and needs-a-reply
items are drafted for you, never published. The wrapper checks its own kill switch: an exit
10 drops the rest of this run to drafts.

## 1. Preflight (stop on any failure, and say which)

- Resolve the PR: `gh pr view <pr> -R <owner/repo> --json number,state,isDraft,author,headRefName,headRepositoryOwner,headRepository,url,headRefOid`.
- It must be OPEN, and `author.login` must equal `gh api user --jq .login`. This skill works
  only on your own PRs; the wrapper refuses anything else (exit 12) anyway.
- The head branch must live in `<owner/repo>` itself (not a fork). A push goes only to that
  branch.
- **Not a board row.** If `${MC_HOME:-$HOME/.claude/mission-control}/state.json` exists and a
  row's `pr` is this PR's URL, stop: that PR belongs to the board, and the loop or a
  `/mission-control` session (`mc changes <KEY>`) handles it. Two writers on one PR branch race.
- Find a checkout: `${SOURCE_DIR:-$HOME/Projects}/<repo name>`. Work in a worktree on the
  head branch (reuse one that already has it checked out; otherwise `git worktree add` it),
  fast-forwarded to `origin/<headRefName>`. Never in a checkout with uncommitted changes.

## 2. Fetch the threads

```bash
gh api graphql -F owner=<owner> -F name=<repo> -F pr=<pr> -f query='
query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){
  reviewThreads(first:100){nodes{id isResolved isOutdated path line
    comments(first:50){nodes{databaseId url body author{login __typename}}}}}
  reviews(first:100){nodes{state body author{login}}}}}}'
```

Keep the unresolved, non-outdated threads. Note each thread's root `databaseId` (the comment
id the wrapper takes), its `url`, the root author's login, and whether that author is a bot
(`__typename == "Bot"` or a login ending in `[bot]`). Bot-rooted threads stay in: their fix
still happens when one is needed, and the wrapper refuses the reply (exit 20), which is a
normal skip. A review summary with a body outside any thread has no comment to reply under,
so it is reported to you and never answered here.

Skip a thread whose last comment is already yours and carries the reply header: it is waiting
on the reviewer, not on you.

## 3. Triage

Classify each thread exactly as `/mission-control`'s "Kickback handling → Branch A" does:

- **mechanical**: typo, rename, clearly correct small fix → fix it.
- **substantive · clear**: a behavior change where the drafted fix is the only reasonable one
  and needs no product or design call → fix it.
- **substantive · judgment**: the reviewer's suggestion needs a call → no code; reply with an
  answer or a decline.
- **needs-a-reply**: a question, or a reviewer who is mistaken → no code; reply with an answer
  or a decline.

Run the consumer check before any reply that defends a fix's mechanism: grep for what reads,
at runtime, the state or path in question. If only specs read it, say so in the reply.

**Held for you** (no code, no reply): an item whose fix touches a path in
`${MC_GATE1_PATH_DENY:-}`, and any item where an honest reply needs a product or design
decision. A held item is listed in the summary, never guessed at.

Print the triage table (thread link, classification, planned fix or reply) before acting.

## 4. Fix and push

For the mechanical and clear items only, in the worktree: one commit per thread (or one
grouped commit naming each thread), no drive-by changes. Run the repo's pre-push
verification (its `AGENTS.md`, or the test and lint commands for the files you touched). Red
→ stop fixing, push nothing, and hold every fix item with the failure named. Green → a normal
`git push origin HEAD:<headRefName>`, never forced. A rejected push (the branch moved) stops
the fix half: hold the fix items, still publish the answers and declines.

Record `{thread, sha, summary}` per fixed thread.

## 5. Write the replies

Every body takes its voice, tone and length entirely from
`${REPLY_STYLE_GUIDE:-${WRITING_STYLE_SKILL:-}}` (read a path, load a skill). This skill sets
none of them; it fixes only what each category must contain:

- **fix** (`--category fix`): what changed and the short SHA.
- **answer** (`--category answer`): the answer, from the code as it is.
- **decline** (`--category decline`): that you will not make the change, and the reason.

A published body **opens with the header line** the wrapper requires: a line that carries the
wrapper's `AUTO_POST_HEADER` text, in the exact form your style guide gives, then ONE empty line,
then the body (`\n\n` between them in JSON). Without the empty line Markdown pulls the body's
first line into the header's blockquote, and the wrapper refuses it (exit 22). A body without it
is refused (exit 21). Cite no commit except the fix's own SHA: the wrapper treats any 7 to 40
character hex word with a digit as a SHA and refuses one not on the head branch (exit 19).
Drafts omit the header, since you publish them yourself.

## 6. Publish or draft

**Publish** (wrapper set): fixes first, then answers, then declines. Write each body to a
file in the scratchpad and call the wrapper bare:

```bash
"${REPLY_POST_WRAPPER:-}" <owner/repo> <pr> <comment-id> <body-file> --category <fix|answer|decline>
```

Route on its exit code, and on nothing else:

- **exit 0**: posted. The last field of its stdout is the reply URL. The wrapper writes the
  work-log line for every post.
- **exit 10**: kill switch present. Draft this reply and every remaining one instead; no
  further wrapper call.
- **exit 20**: the thread was started by a bot account. A normal skip: the fix stands, the
  reply is dropped.
- **exit 30**: reply cap reached. No post; the thread goes to you, listed under "needs you".
- **any other nonzero** (1, 2, 11, 12, 18, 19, 21, 22): stop publishing. No further wrapper call,
  no retry, no other posting route (no draft either). Name the thread and the code.

**Spot-check report.** After each published answer and each published decline (never a fix),
append one entry to
`${MC_AUTO_POST_REPORT:-${MC_HOME:-$HOME/.claude/mission-control}/auto-post-report.md}`
(create it with a `# Auto-post spot-check report` heading if absent; append only):

```
## YYYY-MM-DD · <owner/repo>#<pr> · answer|decline
- thread: <thread url>
- reviewer: <login>
- comment: > <the reviewer's comment, first 300 characters>
- reply: > <the reply text as posted>
- reply URL: <url>
```

and log it, so a decline always leaves a work-log line with `decline` in it:

```bash
"${MC_HOME:-$HOME/.claude/mission-control}/worklog.sh" add --source reply-comments --pr <pr url> --repo <owner/repo> "<answer|decline> posted in thread <comment-id> on <owner/repo>#<pr>, spot-check entry added"
```

**Draft** (wrapper unset, or after exit 10): with `${REPLY_DRAFT_WRAPPER:-}` set, call it bare
as `reply --repo <owner/repo> --pr <pr> --thread <thread node id> --body "<text>"`. Unset,
use GitHub's pending review, which only you can see until you submit it: find your pending
review on the PR (`reviews(states:PENDING)`) or open one with the `addPullRequestReview`
mutation and no `event`, then add each reply with `addPullRequestReviewThreadReply`
(`pullRequestReviewId`, `pullRequestReviewThreadId`, `body`). Never submit the review.

## 7. Summary

Print one table: thread link · classification · outcome (fixed `<sha>` / posted `<url>` /
drafted / bot skip / needs you / refused `<code>` / held). Then:

- `<a>` fixed, `<p>` replies posted, `<n>` drafts pending, `<q>` auto-answered and `<d>`
  auto-declined (spot-check: `<report path>`).
- Needs you: every held, capped (exit 30) and refused thread, with why.
- Drafts pending: submit or discard them on GitHub.

Never resolve a thread, mark the PR ready, request review, or merge. Re-requesting review
after the replies is yours.
