# review-toolkit

Two guarded wrappers that let an agent post PR reviews and thread replies under the
maintainer's GitHub account, without the maintainer reading them first.

## An opt-in exception to the human gate

The toolkit's design principle is that no GitHub review is posted without explicit human
confirmation. These two wrappers are a deliberate, opt-in exception to that rule, built for
an experiment. They are safe to keep in the repo because:

- Every allowlist defaults to empty, and an empty allowlist refuses every post. Nothing is
  posted until someone names the authors and repos in a gitignored `review.env`.
- The guards live in the scripts, not in a prompt. An agent cannot talk its way past them.
- A kill-switch file stops both wrappers before any GitHub call.
- Reviews are COMMENT only. An approval or a change request is refused outright, so the
  merge decision stays with people.
- Replies never resolve a thread. The script has no call that could.

Nothing else in the toolkit calls these wrappers. Using them is a choice made in local
config, per person and per repo.

## Layout

```
review-env.sh      sourced by both wrappers: loads review.env, shared guards and exit codes
example.env        the config template; copy to review.env and fill in
review.env         your allowlists (GITIGNORED)
review-post.sh     post a COMMENT review on an allowlisted author's PR
review-reply.sh    reply in a review thread on your own PR
test/lint.sh       stubbed-gh checks of every guard, no network
```

The config loader is `review-env.sh`, not `env.sh`, so it can share a directory of
symlinks with the jira-toolkit wrappers. Both wrappers resolve their real location through
a symlink, so `review.env` is always found next to the real files.

## review-post.sh

```
review-post.sh <owner/repo> <pr> <payload.json> [--verdict would-approve|would-not-approve] [--dry-run]
```

The payload is a GitHub review body plus the head SHA the review was computed against:

```json
{"head_sha": "abc1234...", "body": "Summary", "comments": [
  {"path": "app/x.rb", "line": 12, "side": "RIGHT", "body": "**must-fix:** handle nil here"}
]}
```

It refuses when the kill switch is present, the event is anything but COMMENT, an inline
comment does not open with a category label (`must-fix`, `should-fix`, `nit`, `question`,
written `label:`, `**label:**` or `[label]`), the repo or the PR author is not allowlisted,
the head moved since the payload was computed, `AUTO_POST_SELF` is not a currently
requested reviewer, or `AUTO_POST_SELF` already reviewed the current head. `--verdict` is
written to the work log and never posted.

Submitting a review clears the request, so a second review on a later head needs a fresh
review request. That is intended.

## review-reply.sh

```
review-reply.sh <owner/repo> <pr> <comment-id> <body-file|-> [--category fix|decline|answer] [--dry-run]
```

It refuses when the kill switch is present, the body lacks `AUTO_POST_HEADER`, the repo is
not allowlisted, the PR is not by `AUTO_POST_SELF`, the comment is not a review comment on
that PR, the thread was started by a bot account, a commit SHA cited in the body is not on
the PR head branch, or `AUTO_POST_SELF` already has `AUTO_POST_MAX_REPLIES` header-carrying
replies in the thread. That last case exits 30 so a caller can hand the thread to a person.

A bot is decided by account type (`user.type == "Bot"` or a `[bot]` login suffix), never by
comment text. A person whose comment carries an automated header is still a person.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `AUTO_POST_AUTHORS` | empty (refuse all) | Comma list of PR author logins `review-post.sh` may review. |
| `AUTO_POST_REPOS` | empty (refuse all) | Comma list of `owner/repo` both wrappers may post in. |
| `AUTO_POST_SELF` | `gh api user` | The maintainer's login. |
| `AUTO_POST_HEADER` | `Automated review` | Text every reply body must contain; also what the reply cap counts. |
| `AUTO_POST_KILL_SWITCH` | `~/.claude/mission-control/auto-post.off` | While this file exists, both wrappers refuse. |
| `AUTO_POST_MAX_REPLIES` | `2` | Header-carrying replies per thread before escalating. |
| `AUTO_POST_WORKLOG` | `../mission-control/worklog.sh` | The work log helper. Each post writes one line. |
| `REVIEW_TOOLKIT_ENV` | `review.env` next to the scripts | Path of the config file. |

Allowlist matching ignores case and spaces. A value set in the environment, even to empty,
wins over `review.env`.

## Exit codes

`0` posted or dry run · `1` a gh call failed · `2` bad arguments or payload ·
`10` kill switch · `11` repo not allowlisted · `12` PR author not allowed ·
`13` not a requested reviewer · `14` event other than COMMENT · `15` unlabeled inline comment ·
`16` already reviewed this head · `17` head moved · `18` comment not on this PR ·
`19` cited SHA not on the head branch · `20` thread started by a bot ·
`21` reply lacks the header · `30` reply cap reached, escalate to a human.
