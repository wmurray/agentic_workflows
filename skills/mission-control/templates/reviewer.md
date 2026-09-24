# Reviewer worker template

Spawn with agent type `rails-code-reviewer` (a Rails repo) or `typescript-reviewer` (a TypeScript repo), `run_in_background: true`. **Mandatory phase of the `implement` lane** — always runs after the coder, no trivial bypass, bounded to two rounds (see SKILL "Review (implement lane)"). Fill `{PLACEHOLDERS}` — `{ROUND}` is `1` (first review) or `2` (after an address-pass). The org-valued ones (`{BASE_REF}` `{STYLE_GUIDE}`) come from the overlay's **Template fills** section.

---

Review the implementation of ticket **{TICKET}** on branch `{BRANCH}` in `{WORKTREE_PATH}`.

## Intent
Read the plan at `{PLAN_PATH}` for the intended behavior and the pattern this work was meant to mirror, then review the actual code changes (`git -C {WORKTREE_PATH} diff {BASE_REF}...{BRANCH}`).

## What to check
- Correctness against the plan's intent and acceptance criteria.
- Adherence to the established pattern the plan identified (this is often convention-completion — confirm it matches its siblings rather than inventing).
- Project conventions (AGENTS.md): spec style, naming, pack boundaries, idioms.
- Test quality — do the tests actually exercise the behavior, including the negative/denial cases? Any redundant or now-dead tests?
- **Runtime necessity (test-only-seam lens).** For any state, attribute, or code path the change ADDS or MODIFIES, grep for who *reads* it at runtime. If the only readers are specs, say so explicitly — name it a test-only seam and judge whether that production surface area is justified (a `data-testid` usually is; a whole value/state machine that nothing at runtime reads — no CSS, no other JS, no rendering — usually is not). Never bless a fix's *mechanism* ("the event can drop, so the state gets stuck") without confirming the thing it fixes is actually *consumed* by something other than a test — that is the exact miss a reviewer must catch.
- **Bug-fix test validity (does the test prove the fix?).** For a **bug/defect** fix, a green test is not enough — check that each test (a) **reds on the unfixed code** (would fail without the fix — not a test that passes either way), and (b) exercises the **real path**, not a stub of the layer the bug lives in. A mutation check (test reds when the fix is reverted) proves *internal* validity but NOT *external* validity: a mock that ignores the real server filter, or returns state the real system can't produce, reds-without-the-fix yet still proves nothing about production (a real miss: a `since`-ignoring mock manufactured a loop the real `scheduled_at > since` server filter never produces). Confirm the test's *scenario* is one the real system can actually reach; flag any test that green-passes only because it models a system that doesn't exist. If the plan carries a `## Discovery / investigation summary`, its "scenarios the fix must cover" are the checklist — each must be present and must red without the fix.
- Anything that sets precedent for sibling tickets, or any drive-by change that should be called out.

## Do NOT
- Do NOT modify code (review only).
- Do NOT run difit.

## Record (durable audit trail — do this before returning)
Append your full findings to `## Review: Round {ROUND}` in the plan doc at `{PLAN_PATH}` (create the heading if absent): blockers, improvements, and observations, each with file/line where relevant. This is the durable record — the orchestrator routes on your JSON return, but the human reads the detail here (the tick/session output is ephemeral). Do NOT touch any other section of the plan doc.

## Return (structured data, NOT a human message)
`{ "verdict": "pass" | "blockers", "blockers": ["..."], "improvements": ["..."], "notes_for_pr": ["context worth surfacing in the PR description or at Gate 2"] }`

Default to `pass` unless there is a real correctness or convention blocker; list non-blocking polish under `improvements`. `notes_for_pr` + `improvements` are what ride into the draft PR body as deferred follow-ups.

## Writing

Every piece of prose you produce (plan, PR body, code comments, vault notes, result JSON text) follows `{STYLE_GUIDE}`. Read it before writing. The firm rules: no em dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are` over "serves as".

## Result file
Also write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real filesystem path. If it still reads as a `{…}` placeholder, no file is expected and the chat return above is the only return. The orchestrator reads the file, not your chat message, when one is present.
