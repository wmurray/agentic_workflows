# Claude Code Skills Toolkit

A personal toolkit of Claude Code skills, agent definitions, slash commands, and shell helpers for software engineering workflows. Built around a multi-agent pattern: a lightweight orchestrator (`/implement`) fans work out to focused coder, reviewer, and specialist agents, then brings results back and gates on human decisions before any outward-facing action.

Everything here is MIT-licensed and designed to be adapted. Internal values (repo names, Jira projects, vault paths) are driven by environment variables — set them once and the whole toolkit picks them up.

---

## What's here

```
agents/          Agent definitions (feature-planner, Rails, TypeScript, and Go specialists)
skills/          Slash commands loaded by Claude Code
commands/        Daily/weekly/review workflow commands
lib/             Shell helpers (workspace context, PR radar)
```

---

## Skills

### Feature development

| Skill              | Description                                                                                                                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/implement`       | Full feature workflow: grill → plan → implement (TDD) → review → summarise → optional draft PR. Orchestrates all the agents below. The centrepiece.                                                     |
| `/tdd-workflow`    | Red-green-refactor cycle for any stack.                                                                                                                                                                 |
| `/grill-with-docs` | Design-challenge session: walks a feature idea through the domain model one question at a time, sharpens terminology, and updates `CONTEXT.md` / ADRs inline. Runs before planning inside `/implement`. |
| `/save-plan`       | Write a feature plan to your notes vault. (Called automatically by `/implement`.)                                                                                                                       |

### Code review

| Skill           | Description                                                                                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/review-pr`    | "Compare notes" PR review — reads the diff, applies the repo's reviewer rubric, produces a structured findings report for a side-by-side discussion. Advisory only; never posts to GitHub. |
| `/review-queue` | Batch review sitting: reviews multiple PRs in parallel in the background, then walks you through each one at a time via difit. Never auto-advances.                                        |
| `/review-radar` | Team-wide monitor: which PRs across your repos are sitting unreviewed, and for how long? Flags the ones waiting on you. Hands off to `/review-queue`.                                      |

### Dependency management

| Skill                | Description                                                                                                                                                        |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/dependabot-triage` | Triage open Dependabot PRs: buckets them (safe to merge / review first / needs code work / close stale), reports the plan, and acts only on explicit confirmation. |

### Maintenance

| Skill                    | Description                                                                                                                                                                                                            |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/strict-refactor-pass`  | Pure rename/extract/simplify refactor — no behaviour changes.                                                                                                                                                          |
| `/audit-debug-artifacts` | Scans changed files for leftover debug statements (`console.log`, `binding.pry`, `debugger`, etc.).                                                                                                                    |
| `/comment-cleanup`       | Removes unnecessary comments left by agents in changed code.                                                                                                                                                           |

### Git / PR lifecycle

| Skill             | Description                                                                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/commit-changes` | Creates logical commits from staged changes following a consistent template.                                                                     |
| `/create-pr`      | Builds a structured PR title and body, links to the ticket, prompts for screenshots. Supports Linear, Jira, or GitHub Issues. Runs preflight checks before calling `gh pr create`.    |

---

## Agents

Loaded from `~/.claude/agents/` as Claude Code subagent definitions.

| Agent                     | Used by                                                                         |
| ------------------------- | ------------------------------------------------------------------------------- |
| `feature-planner`         | `/implement` — explores the codebase, produces a structured implementation plan |
| `rails-feature-developer` | `/implement` — implements Rails features using TDD                              |
| `rails-code-reviewer`     | `/implement` — reviews Rails diffs                                              |
| `rails-backend-expert`    | `/implement` — architecture review for complex Rails changes                    |
| `typescript-developer`    | `/implement` — implements TypeScript/React features                             |
| `typescript-reviewer`     | `/implement` — reviews TypeScript/React diffs                                   |
| `go-developer`            | `/implement` — implements Go features and CLI commands using TDD                |
| `go-code-reviewer`        | `/implement` — reviews Go code for idiomatic patterns and concurrency safety    |

---

## Daily workflow commands

Slash commands for recurring personal workflows. All write to an Obsidian (or compatible markdown) vault and read from GitHub + Jira via the shell helpers.

| Command      | Description                                                             |
| ------------ | ----------------------------------------------------------------------- |
| `/daily`     | Morning standup note: what shipped yesterday, plan for today, blockers. |
| `/eod`       | End-of-day note: update the daily with what actually happened.          |
| `/sitrep`    | Current state across all repos: open PRs, Jira queue, recent commits.   |
| `/weekly`    | Weekly review note synthesized from daily notes + live PR/Jira data.    |
| `/monthly`   | Monthly summary: PRs, tickets, themes.                                  |
| `/quarterly` | Quarterly review: impact, growth, patterns.                             |
| `/yearly`    | Annual retrospective.                                                   |

---

## Shell helpers (`lib/`)

| Script                  | Description                                                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `workspace-context.sh`  | Single gathering script used by all workflow commands. Pulls open PRs, Jira tickets, recent commits, and calendar events into a JSON blob. |
| `review-radar.sh`       | GraphQL query that finds PRs waiting on review, with working-day wait times. Used by `/review-radar`.                                      |
| `pr-bump.sh`            | Records a PR nudge (stamps a comment + updates a local JSON log).                                                                          |

---

## Setup

### 1. Install into `~/.claude`

```bash
# Clone or copy this repo
git clone <repo-url> ~/.claude

# Or, if you already have a ~/.claude, merge selectively:
cp -r agents/ skills/ commands/ lib/ ~/.claude/
```

### 2. Install upstream skills directly (recommended)

Several skills in this repo are adapted from open-source work. If you use those stacks, install from the source repos to get updates:

- **`grill-with-docs`** — [mattpocock/skills](https://github.com/mattpocock/skills)
- **Rails agents + `tdd-workflow`** — [dgalarza/claude-code-workflows](https://github.com/dgalarza/claude-code-workflows)

The versions here may lag behind upstream.

### 3. Install difit (for `/review-queue`)

`/review-queue` uses [difit](https://github.com/yoshiko-pg/difit) to display PR diffs with inline comments. Install it globally or use it via `npx`:

```bash
npm install -g difit
```

### 4. Configure environment variables

> **Note:** The env var system didn't exist in my original config — the scripts had everything hardcoded. I added `${VAR:-default}` overrides when open-sourcing so you can plug in your own values without editing the scripts directly. If you'd rather just hardcode your values (simpler, no shell profile changes needed), that works fine too — just edit the defaults at the top of each script in `lib/`.

Add to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

```bash
# Required by workflow commands and lib helpers
export VAULT="$HOME/Documents/Obsidian/MyVault"   # path to your notes vault
export SOURCE_DIR="$HOME/Projects"                 # root folder containing your repo checkouts
export REPOS="MyApp MyService"                    # space-separated repo names under $SOURCE_DIR
export GH_TEAM="my-org/my-team"                   # GitHub org/team for review radar

# Required by Jira-integrated skills (dependabot-triage, workflow commands)
export JIRA_BASE_URL="https://your-org.atlassian.net"
export JIRA_EMAIL="you@example.com"
export JIRA_PROJECT="ENG"
export JIRA_BOARD_ID="123"

```

### 5. Extend for your stack

The agent routing table in `implement` covers Rails, TypeScript, and Go out of the box. To add another stack (Python, Rust, etc.):

1. Add an agent definition to `agents/`
2. Add a row to the routing table in `skills/implement/SKILL.md`

### 6. Activate in Claude Code

Skills in `~/.claude/skills/` are auto-loaded as slash commands. Agent definitions in `~/.claude/agents/` are available as `subagent_type` values. No additional configuration needed.

---

## Design principles

- **Human gates before outward-facing actions.** No PR is pushed, no Jira ticket is created, no GitHub review is posted without explicit confirmation.
- **Agents return structured results; the orchestrator routes on them.** No file-read chaining — each agent produces a small JSON result and the orchestrator drives the next step from that.
- **Advisory skills never touch GitHub.** `/review-pr`, `/review-queue`, and `/review-radar` are read-only. You write and post your own reviews.
- **Environment variables over hardcoding.** Every organisation-specific value is an env var with a documented default. Nothing internal is baked in.

---

## Adapting this toolkit

This toolkit was built for a specific personal setup. It works out of the box if your stack matches, but every part is designed to be swapped out.

### Tool dependencies

These tools are used by one or more skills. Some are easy to substitute; others are more integral.

| Tool | Used by | Notes |
| --- | --- | --- |
| [`gh`](https://cli.github.com) | Almost everything | Required. All PR and repo operations go through the GitHub CLI. |
| [`jira`](https://github.com/ankitpokhrel/jira-cli) | `workspace-context.sh`, workflow commands | Can be substituted with the Linear CLI, a curl-based wrapper, or omitted if you don't use Jira. Remove the `jira issue list` calls from `lib/workspace-context.sh`. |
| [`difit`](https://github.com/yoshiko-pg/difit) | `/review-queue` | A local diff viewer. Can be replaced with any tool that accepts a GitHub PR URL — or removed if you prefer reviewing in the GitHub UI. |
| [Obsidian](https://obsidian.md) | All workflow commands, `/save-plan`, `/grill-with-docs` | Any directory of markdown files works — set `$VAULT` to point to it. The vault structure (daily notes, sprint retros, etc.) is documented in each command. |

### Issue tracker

Skills that link tickets default to **Jira** (via `$JIRA_BASE_URL` / `$JIRA_PROJECT`) but the format is a one-line change in each skill:

- **Linear**: change ticket URLs to `https://linear.app/YOUR-TEAM/issue/TICKET-NUMBER` and update branch-name parsing patterns
- **GitHub Issues**: use `https://github.com/owner/repo/issues/NUMBER`
- **None**: remove the ticket-linking questions from `/create-pr` and `/make-pr` entirely

### Adding stacks

`/implement` routes to agent pairs by repo type. Rails, TypeScript, and Go are included. To add a new stack, write an agent pair (coder + reviewer) and add a row to the routing table in `skills/implement/SKILL.md`.

---

## License

MIT — see [LICENSE](./LICENSE).

## Credits

Several skills and agents build on work by others — see [CREDITS](./CREDITS) for details:

- **Matt Pocock** ([mattpocock/skills](https://github.com/mattpocock/skills)) — `grill-with-docs` (MIT, adapted)
- **Damian Galarza** ([dgalarza/claude-code-workflows](https://github.com/dgalarza/claude-code-workflows)) — Rails agents (MIT, adapted), `tdd-workflow` (MIT, included verbatim)
- **Dann Berg** ([dannb.org](https://dannb.org/blog/2022/obsidian-daily-note-template/)) — daily note structure and section names (no stated license, attributed with thanks)
