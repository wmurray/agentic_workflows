# Claude User Instructions

## This repo is public

Never commit internal values: no product names, personal names, company names, employer Jira keys, internal URLs, or email addresses. All organisation-specific values must use the `${VAR:-default}` env var pattern documented in `lib/`.

## Repo structure

```
agents/     Agent definitions — loaded from ~/.claude/agents/ as subagent_type values
skills/     Slash command definitions — one directory per skill, each with SKILL.md
commands/   Daily/weekly/review workflow commands
lib/        Shell helpers (workspace-context.sh, review-radar.sh, pr-bump.sh)
```

## Writing skills

Every `SKILL.md` needs frontmatter:

```yaml
---
name: skill-name
description: One-line summary. Used by Claude Code to match the skill to slash commands.
---
```

Optional frontmatter fields:
- `status: incomplete` — marks skills that depend on missing components (e.g. a missing agent)
- `upstream` — URL of the original source if adapted from an open-source skill

If a skill should not be invocable as a subskill (i.e. it must be read and applied directly), add this note inside the skill:

> **Note:** This skill is `disable-model-invocation`. It cannot be called with `/skill-name` from inside another skill — read the file and apply its rules directly.

## Writing agents

Every agent definition needs frontmatter matching Claude Code's agent spec:

```yaml
---
name: agent-name
description: When to use this agent. Be specific — Claude Code uses this to route tasks.
---
```

Agents should be focused on a single language/framework pair or role (planner, coder, reviewer). Do not combine concerns.

## Design principles

When modifying skills or agents, preserve these invariants:

- **Human gates before outward-facing actions.** No PR is pushed, no ticket is updated, no GitHub review is posted without explicit user confirmation.
- **Agents return structured results; the orchestrator routes on them.** Each agent produces a small JSON result. The orchestrator drives the next step from that — never from file reads.
- **Advisory skills never touch GitHub.** `/review-pr`, `/review-queue`, `/review-radar` are read-only. The user writes and posts their own reviews.
- **Env vars over hardcoding.** Every organisation-specific value must be an env var with a documented default. See `lib/workspace-context.sh` for the pattern.

## Workflow

To work on this toolkit itself:

- `/implement <ticket-number>` — full workflow: plan → implement (TDD) → review → summarise. Works with or without an existing plan file.
- `/save-plan` — save a plan to the notes vault manually (`/implement` does this automatically)

### Typical prompt pattern

```
We are working on <ticket-number>. The feature is <brief context>.
Project group: <e.g. Agentic Workflows>
Here's the ticket: <content and acceptance criteria>.
/implement <ticket-number>
```

The agent pauses for review after planning and before writing any code.
