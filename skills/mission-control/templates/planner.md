# Planner worker template

Spawn with agent type `feature-planner`, `run_in_background: true`. Fill `{PLACEHOLDERS}`. The org-valued ones (`{MC_HOME}` `{TICKET_DETAIL_CMD}` `{VAULT_PROJECTS_DIR}` `{CATCH_ALL_GROUP}` `{STYLE_GUIDE}` `{TEST_CONVENTIONS}`) come from the overlay's **Template fills** section.

---

You are planning ticket **{TICKET}** for the **{REPO}** repo at `{REPO_PATH}`. Read `{REPO_PATH}/AGENTS.md` (or `CLAUDE.md`) first for conventions. This is a **PLAN-ONLY** task — do not write any implementation code.

## Ticket {TICKET} — {TITLE}

{TICKET_BODY — paste the full tracker description: context, acceptance criteria, implementation notes, out-of-scope, related links, and any authorization/spec questions verbatim.}

{DISCOVERY_SUMMARY — for a bug/defect ticket with an `evidence` pointer on the board, paste the linked investigation note here under a `## Discovery / investigation summary` heading: the reported repro, device logs, error-tracker/telemetry traces, and prior root-cause findings. This is AUTHORITATIVE — ground your mechanism in it; do not re-derive around it. OMIT this block entirely for feature/chore tickets or bugs with no discovery evidence.}

## Your tasks

1. Read the project conventions and the affected files named in the ticket.
2. Explore the codebase for the **established pattern** this work should mirror — find 1–2 sibling implementations and follow them exactly (naming, structure, helpers, permission/grant idioms). Note if this is convention-completion vs. novel design.
3. Inspect any referenced branches/commits the ticket says to "port" — verify the claim before trusting it (a referenced commit may already be on main, or may do the opposite of what's intended).
4. Produce a step-by-step **TDD** plan following the `/execute-plan` convention (empty `it`/`context` blocks first, then one failing test at a time → minimal code → pass). {TEST_CONVENTIONS — the repo's spec-style rules from the overlay's Template fills (layout, factory use, mocking policy); omit this sentence if the overlay has none for this repo.} Cover every scenario the ticket names.
5. **Choose the project-group folder — epic-driven; create a folder only when a real epic drives it.** Resolve the folder in this order:
   - **a. Find the ticket's epic (parent).** It may already be in `{TICKET_BODY}`; if not, run `{TICKET_DETAIL_CMD}` for {TICKET} and read the Epic / parent link. Note both the epic key (e.g. `ABC-1692`) and its summary (e.g. `Payments Platform Migration`).
   - **b. No epic** → use the catch-all **`{CATCH_ALL_GROUP}`**.
   - **c. Epic is in the catch-all denylist** — read `{MC_HOME}/catch-all-epics.txt` (one entry per line, `#`/blank lines ignored; match case-insensitively against the epic key OR summary) → use **`{CATCH_ALL_GROUP}`**. These epics are grab-bag buckets, not projects.
   - **d. Otherwise** → the folder is the **epic's summary** (the name, not the key — e.g. `Payments Platform Migration/`). `ls -d {VAULT_PROJECTS_DIR}/*/` first; if a folder matching that name already exists (case-insensitive) use it **exactly as it exists on disk**, else **create it with `mkdir -p`**.
   - **e. NEVER name a folder after the repo** — a bare `<repo name>/` folder is the wrong outcome; the `{REPO}` is not the project group. If you cannot determine an epic name and no existing folder matches, fall back to `{CATCH_ALL_GROUP}`, never the repo. The `{PROJECT_GROUP}` value passed to you is only a HINT — the epic wins; use the hint only to disambiguate a folder-name match.

   Then save to `{VAULT_PROJECTS_DIR}/<chosen group>/{TICKET} {Short Title} Plan.md` and tell me the exact path.

## Return (structured data, NOT a human message)

(a) saved plan file path
(b) numbered distilled step list (one line each)
(c) any **OPEN QUESTIONS** needing a human decision before coding — and for each, **your recommended answer** based on how the sibling implementations are written (so the human confirms rather than derives)
(d) test strategy (the cases and how each is arranged)
(e) risks / surprises in the existing code — especially: is there already a failing spec, or is this defense-in-depth with no current failure? Any ticket claim that didn't hold up on inspection?

## Writing

Every piece of prose you produce (plan, PR body, code comments, vault notes, result JSON text) follows `{STYLE_GUIDE}`. Read it before writing. The firm rules: no em dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are` over "serves as".

## Result file
Also write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real filesystem path. If it still reads as a `{…}` placeholder, no file is expected and the chat return above is the only return. The orchestrator reads the file, not your chat message, when one is present.
