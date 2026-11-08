---
name: pr-body
description: The layout of a pull request description: Summary, Evidence, Merge Risk Report and a ticket line, under a counted word cap. Load it whenever you write or rewrite a PR body, by hand or from a loop. The voice is writing-style's; this skill only fixes the shape.
---

# PR body

A PR body is read by a reviewer deciding how hard to look. Give them the change, the proof
and the risk, in that order, and nothing they have to scroll past. Write the prose in the
writing-style skill's voice.

## Layout

```markdown
<Summary: what changed and why, in two to four sentences. The first sentence is the change.>

<Sketch, when one fits: the smallest picture of the new behaviour. A call and its output,
a before and after, a short table of cases. Omit it for a change with nothing to show.>

## Evidence

- `<command>`: <its result, e.g. "212 passed, 0 failed">
- <capture or artifact path, and what it shows>

## Merge Risk Report

- Door: <two-way | one-way>. <One line naming what a revert would leave behind, or that it leaves nothing.>
- Blast radius: <small | medium | large>. <One line naming the file, flag or behaviour it rests on.>

Ticket: <KEY>
```

- **Summary** has no heading; it is the body's opening. It says the change and its reason.
  It does not list files or commits; the diff does that.
- **Evidence** lists what was run and what it showed: the exact command and its result,
  captures with what each frame shows. "Tests pass" with no command is not evidence. If a
  check could not run, say so and why; do not leave it out.
- **Merge Risk Report** is required on any code change; a docs-only or config-only PR may
  omit it. Rate both lines:
  - Door: two-way means reverting the merge undoes it completely. One-way means a revert
    leaves something behind: a migration that drops, renames or backfills data; data sent
    to a third party; a changed external contract (an API or schema a released client reads,
    a webhook or event payload); a removed flag or environment variable; anything a deploy
    runs once.
  - Blast radius: small is one feature, one narrow code path, or behind a flag. Medium is a
    shared component, or every user of one flow. Large is auth, payments, personal-data
    egress, background-job infrastructure, or every request.
- **Ticket line** is last: `Ticket: <KEY>` with the tracker's key exactly as the tracker
  spells it, or `No ticket: <reason>`.
- Add a heading only for something a reviewer must act on that fits none of the above (a
  migration step, a stacked-PR base). Otherwise no other headings, and no empty sections.

## What a PR body leaves out

- No `🤖` marker line at the top; that marker belongs to comments and replies. A
  generated-by footer at the very end is fine where the operator's harness adds one,
  unless the repo or team says otherwise. It is not counted toward the cap.
- No restated diff, no file-by-file list, no commit list.
- No em dashes.

## The cap

At most **250 prose words**, or **325** when the diff changes more than 175 lines. Prose is
everything outside code fences, tables, headings, the ticket line and a generated-by
footer. Count it before posting:

```bash
scripts/prose-words.sh body.md                 # prints the count
scripts/prose-words.sh body.md --check 250     # exit 1 when over
git diff --shortstat origin/main...HEAD         # changed lines, for the 325 cap
```

Over the cap is not done. Cut the sketch first, then the Summary's second half; never cut
Evidence or the Merge Risk Report to fit.
