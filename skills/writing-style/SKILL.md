---
name: writing-style
description: The voice for any prose a person reads, whether written by you or by an agent on your behalf: PR bodies, commit messages, review comments, replies, ticket text, notes and terminal summaries. Load it before writing any of those. Layout for a PR body is in pr-body; code comments are in comment-cleanup's RULES.md.
---

# Writing style

One rule underneath every other: **say the specific thing.** Models regress to the mean.
They trade the load-bearing fact for a general, positive, widely true statement, and the
writing gets vaguer and more emphatic at the same time. Every rule below is a symptom of
that. When in doubt, add the fact and cut the adjective.

This is calibration, not a banned-words list. A list of words to avoid puts those words in
front of the model, and the synonyms are usually fine. Read for the pattern.

## Who reads it decides the shape

Ask who reads the text before writing a word.

- **A person on another team, a reviewer, a ticket watcher:** the rules here, plus the
  surface's own shape (pr-body for a PR, the caps below for the rest).
- **Only the operator** (a plan, a run report, a terminal summary): the rules here; the
  outcome comes first, and a group has at most five items.
- **Only a script** (a result file, a record, a verdict): its fixed shape and no prose rule.

## Lead with the result

- The first sentence says what happened or what is being asked. Context comes after.
- Keep the why. A change without its reason is the part a reader cannot recover later.
- One idea per paragraph. Stop when the point is made: no recap, no hopeful closing line,
  no "let me know if".

## Use the reader's words

- Ticket keys, PR numbers, flag names, file paths, function names and people's names come
  from the repo, the ticket and the thread, spelled as they are spelled there.
- A name coined during the work (an internal label for an approach, a nickname for a bug)
  gets plain words instead. The reader never saw it.
- Name the source of a claim, or drop the claim. No "it's widely considered", no
  "best practice says".

## Sentences

- Use `is`, `are` and `has`. Not "serves as", "stands as", "functions as", "represents",
  "boasts", "features".
- No trailing participle clause that adds a vague claim: "..., ensuring consistency",
  "..., highlighting the need for", "..., reflecting the broader pattern". Cut it, or make
  it its own sentence with a real claim in it.
- No negative parallelism ("not X, but Y", "it isn't A, it's B", "X rather than Y"). State
  the positive claim alone.
- Use the number of items you have. Two is fine; do not reach for a third.
- Repeat a noun instead of rotating synonyms for it. "The cache... the cache" reads better
  than "the cache... the store... the layer".
- No significance inflation: "plays a crucial role", "is a testament to", "marks a turning
  point", "sets the stage for". If it matters, the fact shows it.
- No promotional register: seamless, robust, powerful, elegant, comprehensive, vibrant.
- A cluster of these is the signature to watch for: additionally (opening a sentence),
  crucial, delve, enhance, foster, highlight (as a verb), key (as an adjective), landscape,
  leverage, meticulous, pivotal, showcase, underscore. One is a coincidence.
- No aphorism to close a paragraph ("the asymmetry is the tell").

## Formatting

- **No em dashes.** Use a comma, a colon, parentheses or a full stop. This is the one rule
  every check enforces mechanically.
- Sentence case for headings.
- Bold sparingly: a term once where it is defined, not every mention.
- No emoji on headings or bullets, and no `---` rule between every section.
- Prose or a plain list by default. A page made of `- **Label**: text` bullets is a tell.
- A table only when there are rows and columns to compare. Two facts are a sentence.

## The agent marker

Text posted from the operator's account in a conversation (a review comment, a reply to a
reviewer, a ticket comment, a chat message) opens with one line naming the agent and the
model, for example `> 🤖 From <operator>'s agent (<model>)`. A PR body, a commit message
and a ticket field carry no marker and no generated-by footer; the commit's
`Co-Authored-By` trailer is the attribution.

## Caps by surface

| Surface | Shape | Cap |
| --- | --- | --- |
| Commit message | subject under 72 characters in the imperative; body says why | none |
| Review comment | one finding, the evidence for it, one action; a Conventional Comments label | 80 words |
| Reply to a reviewer | what changed with the commit SHA, or the answer, or the decline and its reason | two sentences |
| Ticket description | the goal first, then the ticket template's sections | 200 words of prose |
| Ticket comment | the update first, ending with `Next:` and who owns it | 120 words |
| PR body | see pr-body | see pr-body |

Count the words; do not estimate them. Over the cap is not done.

## Talking to the operator

No "Great question", "Certainly", "I hope this helps", "Here's a breakdown". Answer, then
stop. Do not overcorrect either: structure that carries information (a comparison table, a
grouped summary) is welcome. The goal is text that carries specific facts, not text scrubbed
of every word on a list.
