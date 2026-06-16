---
name: implement
description: Implement a feature end-to-end using the appropriate agent team. If a plan file already exists, reads it and runs coder → reviewer → address feedback → reviewer → summary → optional draft PR. If no plan file exists yet, spawns feature-planner first, saves the plan, and pauses for review before executing. Accepts a ticket number (e.g. /implement PROJ-652) or a full file path. Resumable — skips already-completed steps if restarted mid-way.
---

Execute a feature plan using the full agent team workflow.

Each agent receives a focused prompt and returns a small structured result. The orchestrator routes on those results — never on file reads. Agents write to the plan file as a side effect for audit trail purposes only.

## Step 1: Find or create the plan file

**If given a file path:** verify it exists and skip to Step 2.

**If given a ticket number:** search for an existing plan file:
```
$VAULT/Projects/**/<ticket number>*.md
```

**If a plan file is found:** proceed to Step 2.

**If no plan file is found:** ask the user for:
- Ticket title / one-line summary
- Repository (the repo name, e.g. `my-rails-app` or `mobile-app`)
- Project group — the Obsidian parent directory (e.g. `Authentication Improvements`). Look at the ticket or branch name for clues before asking.
- Brief description of what needs to be built (1–2 sentences)

### Step 1a: Grill before planning

Invoke the `grill-with-docs` skill to stress-test the idea before `feature-planner` runs. The grill should:
- Read the org glossary (if one exists) and the relevant project's `CONTEXT.md` (or per-pack `CONTEXT.md`s for multi-pack projects)
- Walk the design tree one question at a time, sharpening terms and surfacing conflicts
- Update `CONTEXT.md`(s) inline as terms resolve
- Offer ADRs only when hard-to-reverse + surprising + a real trade-off

The grill ends by handing back: resolved terms, ADRs created, open questions still pending, and scenarios the planner should explicitly cover. **Pause** for user confirmation before continuing to feature-planner — the user may want to skip the grill (`/implement ... --skip-grill` or "skip the grill, go straight to planning") for trivial tickets.

If the user opts out of the grill at this step, proceed directly to spawning `feature-planner`.

### Step 1b: Plan

Spawn the `feature-planner` agent, passing all of the above including the project group, **plus the grill's handoff summary** (resolved terms, open questions, scenarios to cover). It will explore the codebase, produce a structured plan, and save it to Obsidian via `save-plan` using the project group provided.

**Pause.** Present the plan file path to the user and ask: *"Does this plan look right? Any changes before I start implementing?"* Wait for explicit confirmation before continuing.

## Step 2: Read routing info

Read only the frontmatter of the plan file:
- `repo` — determines which agents to use
- `complexity` — determines whether architecture review is needed

Also scan `## Implementation Steps` for any pre-ticked checkboxes (`- [x]`) — these are already complete and will be skipped in Step 5.

Surface any unticked `## Open Questions` to the user before proceeding.

## Step 2.5: Ensure feature branch

Before implementing, ensure we are **not** on `main` or another integration branch.

Run `git branch --show-current` to check the current branch.

**If on `main` (or an integration branch like `develop`):**
1. Search for an existing branch for the ticket: `git branch --list "*<ticket-number>*"`
2. If found → `git checkout <branch>`
3. If not found → create and check out: `git checkout -b <initials>-{ticket-number}-{short-description}` (e.g. `ab-PROJ-42-add-auth`, kebab-cased from the ticket title)
4. Tell the user which branch we're now on

**If already on a feature branch** → proceed, no action needed.

Never commit implementation work to `main`. This step must complete before spawning any coder agent.

## Step 3: Select agents

| Repo type | Coder | Reviewer |
|-----------|-------|----------|
| Ruby on Rails | `rails-feature-developer` | `rails-code-reviewer` |
| TypeScript/React | `typescript-developer` | `typescript-reviewer` |
| Go | `go-developer` | `go-code-reviewer` |

The `repo` field in the plan file identifies the codebase. Map it to the correct agent pair based on what's actually in the repo.

## Step 4: Architecture review (Rails + complex only)

If the repo is a Rails project (maps to `rails-feature-developer`) AND `complexity: complex`, spawn `rails-backend-expert` with:

> Read the plan at `<path>`. Validate the architectural approach — pack boundaries, data model, service object design. Append any concerns to the plan file under `## Architecture Notes`. Return JSON only: `{ "approved": true/false, "concerns": ["..."] }`

If `approved: false`, surface the concerns to the user and ask whether to revise the plan before continuing.

## Step 5: Implement

Spawn the **coder agent** with:

> Read the plan at `<path>`. Read the project's `CLAUDE.md` (or `AGENTS.md`) for the lint command. Skip any steps whose checkboxes are already ticked (`- [x]`) — these are complete. For each remaining step, use the `tdd-workflow` skill to implement and test. When a step's tests pass: run the lint command, stage the relevant files with `git add`, tick its checkbox in the plan file (`- [ ]` → `- [x]`), then commit following the conventions in `skills/commit-changes/SKILL.md` — **Read that file and apply its rules directly; it is `disable-model-invocation` and CANNOT be invoked as a skill.** When all steps are done, write a brief summary to `## Implementation Notes` in the plan file. Return JSON only: `{ "steps_complete": [1, 2], "steps_incomplete": [3], "deviations": "description or none" }`

## Step 6: Review — round 1

Spawn the **reviewer agent** with:

> Read the plan at `<path>` for intent, then review the code changes. Write your findings to `## Review: Round 1` in the plan file (blockers, improvements, observations). Return JSON only: `{ "verdict": "pass" or "blockers", "blockers": ["..."], "improvements": ["..."] }`

Route on the returned `verdict`:
- `"pass"` → skip to Step 8
- `"blockers"` → proceed to Step 7

## Step 7: Address blockers

Spawn the **coder agent** with:

> Read the plan at `<path>`. Address these specific blockers from the reviewer: `<paste blocker list from Step 6 return value>`. Run the lint command from `CLAUDE.md` (or `AGENTS.md`), stage the relevant files with `git add`, and commit following the conventions in `skills/commit-changes/SKILL.md` (**Read and apply it directly — it cannot be invoked as a skill**). Return JSON only: `{ "addressed": ["blocker 1", "blocker 2"] }`

## Step 8: Review — round 2 (final)

Spawn the **reviewer agent** with:

> Read the plan at `<path>` for intent, then review the updated code. Write your final verdict to `## Review: Round 2` in the plan file. Return JSON only: `{ "verdict": "pass" or "unresolved", "summary": "one sentence", "unresolved": ["..."] }`

Route on the returned `verdict`:
- `"pass"` → proceed to Step 9.
- `"unresolved"` → **stop and ask the user** (do not auto-loop — this is the runaway guard). Present the `unresolved` list and offer:
  1. **Round 3** — run another address-blockers (Step 7) + review (Step 8) cycle on just these items.
  2. **Accept** — proceed to Step 9 and record the unresolved items as follow-ups.
  3. **Take over** — handle them manually.

  If the user picks Round 3, run exactly one more Step 7 → Step 8, then return here and ask again. Never start another round without the user's explicit say-so — the loop only ever advances on a human decision, however many times they choose to continue.

## Step 9: Summarise

Using only the return values collected across steps (not file reads), report to the user:
- Steps complete vs incomplete (from Step 5 return)
- Whether this was a resume (steps were skipped)
- Round 1 blockers found and whether resolved (from Steps 6 and 7 returns)
- Improvements deferred (from Step 6 return) — candidates for follow-up
- Final verdict (from Step 8 return)
- Plan file path for reference

## Step 10: Offer to open a draft PR

The pipeline stops short of publishing by default. After summarising, **offer** — do not act without confirmation, since pushing and opening a PR are outward-facing:

> "Want me to push `<branch>` and open a **draft** PR?"

If declined, stop here. If confirmed:
1. Push the branch: `git push -u origin <branch>` (the branch from Step 2.5 / `git branch --show-current`).
2. Build the PR title and body by following `skills/create-pr/SKILL.md` — **Read that file and apply its "Output Contract" rules directly; it is `disable-model-invocation` and CANNOT be invoked as a skill. Skip the CREATE Mode preflight — branch push is already handled above.** Infer the ticket number from the branch/plan for the `[TICKET]: <desc>` title, and ask create-pr's two follow-up questions (Screenshots? Ticket tracker link?) before finalizing.
3. Create it as a **draft**: `gh pr create --draft --title "..." --body "..."`.
4. Return the PR URL.

Draft is the deliberate default — it signals "loop closed, not yet review-ready" and leaves the final mark-ready / merge decision to you.
