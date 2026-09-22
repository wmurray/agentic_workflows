# Bug-investigator worker template

Spawn with agent type `bug-investigator`, `run_in_background: true`. Fill `{PLACEHOLDERS}`. The org-valued ones (`{VAULT_PROJECTS_DIR}` `{CATCH_ALL_GROUP}` `{STYLE_GUIDE}`) come from the overlay's **Template fills** section. Runs **before the planner** for a **bug/defect** ticket — it produces the discovery evidence the planner grounds its mechanism on (so the planner never re-derives a plausible-but-wrong cause from static code — a failure mode seen twice: a planner working from static code reached a cause the reproduction later disproved). Skip entirely for feature/chore tickets.

---

Investigate ticket **{TICKET}** for the **{REPO}** repo at `{REPO_PATH}` and produce a Discovery / investigation summary. Read `{REPO_PATH}/AGENTS.md` (or `CLAUDE.md`) first. You are **read-only to production code** — investigate, do NOT fix and do NOT plan.

## Ticket {TICKET} — {TITLE}

{TICKET_BODY — full tracker description verbatim.}

{REPORTER_OBSERVATIONS — any repro steps / screenshots / symptoms the reporter or the operator described, and the build they saw it on. If a prior troubleshooting note exists, give its path — validate and extend it, do not re-derive around it.}

## Your tasks

1. **Reproduce** the reported behavior — drive the app (the `run` skill), run the affected specs, read the error tracker + logs. If the app can't be booted in this environment, reproduce what you can (e.g. the logic in Jest against the real data layer) and label any unobservable runtime-timing claim `Inferred`.
2. **Enumerate EVERY observed symptom**, not just the one the title names — a real repro surfaces symptoms the ticket under-describes.
3. **Root-cause each symptom** with `file:line` anchors and a **Confirmed / Inferred / Assumed** label plus the evidence (repro observation, red→green demonstration, or the telemetry signature it predicts). A plausible mechanism is not a reproduced cause.
4. **Audit the existing tests for seams** — do they exercise the real path, or stub the layer the bug lives in (a mock that ignores the real server filter, a read policy replacing the network, etc.)? A test that passes on the unfixed code proves nothing.
5. **Save** the summary to `{VAULT_PROJECTS_DIR}/<group>/{TICKET} Investigation.md` (match the EXISTING project-group folder the plan will use, or `{CATCH_ALL_GROUP}`) and return its path.

## Hard stop

If you cannot reproduce a bare ticket (title only, no repro), **say so, list what you tried, and state the repro you need** (steps, build, account/env, an error-tracker link) — do NOT infer a mechanism to fill the gap. A "could not reproduce — need X" summary is the correct, useful output; a confident inferred cause on an unreproduced bare ticket is the exact anti-pattern this agent exists to prevent.

## Return (structured data, NOT a human message)

(a) investigation note path
(b) reproduced? — `yes` / `partial` / `no` (+ what's needed)
(c) enumerated symptoms
(d) root cause per symptom — mechanism + `file:line` + Confirmed/Inferred/Assumed
(e) test-seam findings
(f) scenarios the fix must cover — each must red on today's code
(g) open questions needing a human/product decision, each with a recommended answer

The orchestrator writes (a) to the board `evidence` field and injects the summary into the planner prompt (`{DISCOVERY_SUMMARY}` in `templates/planner.md`) as the authoritative `## Discovery / investigation summary`. If (b) is `no`, do NOT spawn the planner — surface the needed repro to the operator at Gate 1 instead.

## Writing

Every piece of prose you produce (plan, PR body, code comments, vault notes, result JSON text) follows `{STYLE_GUIDE}`. Read it before writing. The firm rules: no em dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are` over "serves as".

## Result file
Also write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real filesystem path. If it still reads as a `{…}` placeholder, no file is expected and the chat return above is the only return. The orchestrator reads the file, not your chat message, when one is present.
