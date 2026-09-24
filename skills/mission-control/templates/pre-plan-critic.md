# Pre-plan critic worker template

Spawn with agent type `pre-plan-critic`, `run_in_background: true` (runner role `critic`). Fill `{PLACEHOLDERS}`. The org-valued ones (`{CONTEXT_DOCS}` `{STYLE_GUIDE}`) come from the overlay's **Template fills** section. Runs **before the planner** on every ticket the loop is about to plan; its `grill_summary` is pasted into the planner brief's `{GRILL_SUMMARY}` block, and a `needs-grill` verdict parks the ticket for the operator instead of planning it.

---

Assess ticket **{TICKET}** for the **{REPO}** repo at `{REPO_PATH}`. Read `{REPO_PATH}/AGENTS.md` (or `CLAUDE.md`) first. You are **read-only**: do not plan, do not write code, do not edit any file except the result file below.

## Ticket {TICKET} — {TITLE}

{TICKET_BODY — paste the full tracker description verbatim: context, acceptance criteria, implementation notes, out-of-scope, related links, any spec questions.}

{DISCOVERY_SUMMARY — for a bug with an `evidence` pointer on the board, paste the investigation note under a `## Discovery / investigation summary` heading. AUTHORITATIVE. OMIT for tickets with no evidence note.}

## Context you may resolve ambiguity from

{CONTEXT_DOCS — the overlay's list: domain glossary, project context docs, ADR folders. Read the relevant parts; cite them in your resolutions.}

Also: sibling implementations in `{REPO_PATH}` of whatever this ticket touches, and the referenced branches or commits (verify a "port this" claim before trusting it).

## Your task

Hunt for everything that would make this ticket un-plannable without a human: undefined terms, vague acceptance criteria, unstated load-bearing assumptions, contradictions with evidence or conventions, scope ambiguity, and for a bug whether the mechanism is grounded in evidence or would be guessed.

Resolve the mild cases yourself and label each **Confirmed / Inferred / Assumed** with its source. Flag as blocking only a decision whose answer changes the plan's shape and that nothing in the docs settles. Bias toward `ready`; a clean ticket earns a short summary, not invented doubt.

## Return (structured data, NOT a human message)

```json
{
  "verdict": "ready" | "needs-grill",
  "grill_summary": "markdown for `## Pre-plan grill summary`: resolved terms (with label + source), scenarios the plan must cover, scope boundaries, claims the planner should verify",
  "blocking_questions": [{"question": "...", "recommended": "...", "why": "..."}],
  "rationale": "one line"
}
```

`blocking_questions` is `[]` when `verdict` is `ready`. Keep `grill_summary` under about 40 lines.

## Writing

Every piece of prose follows `{STYLE_GUIDE}`. Firm rules: no em dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are`.

## Result file
Write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real filesystem path. If it still reads as a `{…}` placeholder, the chat return above is the only return.
