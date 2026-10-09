# Field-check worker template

Spawn with agent type `general-purpose`, `run_in_background: true`, through the runner seam as role
`fields`. **Read-only: this worker drafts, it never writes to the tracker or the PR host.** The loop
spawns it on a merged ticket in `alpha-verify` while the `fields` guard is open (driver Prep-write 6);
a manual session may spawn it for the same job. The orchestrator writes the fields from the JSON this
returns, through the field wrappers, and moves the tracker to QA once every field is set. Fill `{PLACEHOLDERS}`; the org-valued ones (`{TICKET_DETAIL_CMD}`
`{STYLE_GUIDE}`) come from the overlay's **Template fills** section, `{SURFACES}` from its Surfaces section.

---

Draft the post-merge fields for ticket **{TICKET}**, merged as `{REPO}#{PR}`.

## Read
- The ticket, including its acceptance criteria: `{TICKET_DETAIL_CMD}`
- What shipped: `gh pr view {PR} -R {REPO} --json title,body,files` and `gh pr diff {PR} -R {REPO}`
- The plan at `{PLAN_PATH}` (its test strategy, and any edge cases it flagged). `(none)` = no plan doc.
- The feature flags the coder captured on the board: `{FEATURE_FLAGS}` (`[]` = not flagged, `absent` = never captured).
- Which app renders which code: `{SURFACES}`

## Draft
1. **Release note** (SKILL "Release notes"). Classify it:
   - `internal` (spec, dependency bump, refactor, tooling, perf with no visible change) → `Internal: <brief note>`.
   - `user-facing` → one or two sentences in user language: what the user can now do or will notice. No class
     names, constants or file paths.
2. **Testing notes** (SKILL "QA test cases"). Lead with the surface (which app, and the path to the view),
   decided from the code the diff touches. 3 to 7 cases: one happy path, the edge cases the plan flagged, one
   regression guard. Each case is **Scenario** · **Steps** · **Expected**, tagged `[User-visible]` unless
   there is no user-facing signal. End with **Not covered** and why. Only steps a tester can run on alpha.
3. **Feature flags.** Do not choose flags. Compare the diff with `{FEATURE_FLAGS}`: if the diff reads or
   adds a flag the board does not list, or the board lists one the diff never touches, say so in `blockers`.
4. **Post-release tasks.** A step someone must take after this ships and before it is complete: a data
   backfill, a flag to flip, a config or environment change, a one-off script. Name only what the diff or the
   ticket shows. None is the common answer; return `[]`.

## Confidence
Set `confident: false` on a draft, with a one-line `why`, when any of these hold:
- The ticket's intent and the merged diff disagree, or the diff is much larger than the ticket.
- You cannot tell which app renders the change.
- A test case needs data, access or tooling that alpha does not have.
- You cannot tell whether the change is visible to users.
A confident wrong field costs more than an honest hold; the operator fills a held field in a minute.

## Do NOT
- Do NOT write any tracker field, comment, label or transition, and do NOT edit the plan doc.
- Do NOT read or set story points. The orchestrator checks them; nothing writes them.
- Do NOT file a sub-task for anything.

## Return (structured data, NOT a human message)
```json
{
  "release_note":  { "text": "...", "kind": "internal" | "user-facing", "confident": true, "why": "" },
  "testing_notes": { "text": "markdown cases", "confident": true, "why": "" },
  "post_release":  ["one line per task"],
  "blockers":      ["anything the operator must decide before QA, e.g. a flag mismatch"]
}
```

## Writing

Every piece of prose you produce follows `{STYLE_GUIDE}`. Before writing, read it if it is a file path, or load it if it names a skill. The firm rules: no em
dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are` over
"serves as".

## Result file
Also write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real
filesystem path. If it still reads as a `{…}` placeholder, no file is expected and the chat return above is
the only return. The orchestrator reads the file, not your chat message, when one is present.
