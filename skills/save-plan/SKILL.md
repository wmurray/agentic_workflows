---
name: save-plan
description: Save a feature implementation plan to the notes vault. Formats the current plan into a structured markdown file and writes it to $VAULT/Projects/<Project Group>/<Ticket Number> <Title> Plan.md
---

Save the current feature plan to the Obsidian vault at `$VAULT/Projects/`.

## Steps

1. **Gather required information** — if any of the following aren't already known from context, ask for them before proceeding:
   - Ticket number (e.g. `PROJ-652`)
   - Ticket title / one-line summary (e.g. `Add new feature to improve onboarding`)
   - Project group — the parent directory under `Projects/` (e.g. `Onboarding Improvements`). Look at the ticket or branch name for clues before asking.
   - Repository (the repo name, e.g. `my-app`)

2. **Determine the file path:**
   ```
   $VAULT/Projects/<Project Group>/<Ticket Number> <Ticket Title> Plan.md
   ```
   Example: `$VAULT/Projects/Onboarding Improvements/PROJ-652 Add new feature to improve onboarding Plan.md`

   **If the project group has a `Plans/` subdirectory, save there instead:** `.../Projects/<Project Group>/Plans/<Ticket Number> <Ticket Title> Plan.md`. Check with `ls -d "<group dir>/Plans"`. Don't create `Plans/` in a folder that lacks one; the folder's owner decides its layout. `/execute-plan` finds plans in either place because it searches `Projects/**/`.

3. **Create the project group directory if it doesn't exist** using `mkdir -p`.

4. **Write the plan file** using this template — populate every section from the plan discussed in the conversation. Omit sections that don't apply (e.g. no Data Model Changes for a frontend-only task).

```markdown
---
ticket: <TICKET-NUMBER>
repo: <REPO>
complexity: standard
date: <TODAY>
---

# <TICKET-NUMBER>: <Ticket Title>

## Context
<Why this is being built — 1-2 sentences of business/product context>

## Affected Areas
- `<path>` — <what changes here>
- `<path>` — <what changes here>

## Data Model Changes
<New tables, columns, migrations, associations — omit section if none>

## Implementation Steps
- [ ] **Step 1:** <description>
  - *Test:* <what to verify>
- [ ] **Step 2:** <description>
  - *Test:* <what to verify>

## Open Questions
- [ ] <anything unresolved that should be clarified before or during implementation>

---

## Implementation Notes
<!-- Coder writes here: what was built, any deviations from the plan, decisions made -->

## Review: Round 1
<!-- Reviewer writes here after initial implementation -->
### Blockers
### Improvements
### Observations

## Review: Round 2
<!-- Reviewer writes here after corrections, if needed -->
### Result
```

5. **Confirm** by outputting the full file path where the plan was saved.
