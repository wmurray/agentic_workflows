---
name: reflect
description: Mine the current session for durable learnings with three parallel reviewers (judgment, tooling, divergent) and a synthesizer, then route each finding to a gated skill edit, the overlay candidate table, or an Obsidian backlog. Use when Will says reflect or /reflect.
---

# Reflect

Adapted from pstack's `reflect` (michael-denyer/pstack-claude, 2026-10-28). The four prompt
templates in `references/` are pstack's, verbatim. What is ours: the routing in step 5, the
gate in step 6, and no model sheet.

Skip when the conversation is trivial, off-topic, or already covered by a skill the session
followed correctly. One-offs are not learnings.

## 1. Locate the transcript

The session's transcript is `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. The
harness names it in the compaction summary; otherwise run the finder with the projects
directory and a fragment of the opening prompt:

```bash
dir=$(node ~/.claude/skills/reflect/scripts/claude-project-dir.mjs) && node ~/.claude/skills/reflect/scripts/find-transcript.mjs "$dir" "<opening prompt fragment>"
```

Do not glob across other projects' directories. If the finder exits 1, write a digest (one
line per turn: prompts, tool calls, files touched, no diagnosis) and pass that instead.

## 2. Spawn three reviewers in parallel

One message, three `Agent` calls, `subagent_type: "general-purpose"`, named
`reflect-judgment`, `reflect-tooling`, `reflect-divergent`. Pass each template verbatim with
the transcript path substituted; add nothing else, not even a focus note.

| Lens | Template |
|---|---|
| Judgment | `references/judgment-reviewer.md` |
| Tooling | `references/tooling-reviewer.md` |
| Divergent | `references/divergent-reviewer.md` |

Agent results truncate in the notification. Ask each reviewer to write its full list to
`<scratchpad>/reflect-<lens>.md` and reply with one line; wait for all three files.

## 3. Synthesize

One `Agent` call, `general-purpose`, named `reflect-synth`. Pass `references/synthesizer.md`
with the three file paths in place of the inlined outputs, and ask it to write its output to
`<scratchpad>/reflect-synthesis.md` as well as return it.

## 4. Structural enforcement check

Move any Accepted item that a lint rule, script, metadata flag or runtime check would enforce
more reliably to Backlog, and say so in the table. Skill prose is for what a mechanism
cannot check.

## 5. File the Backlog, before asking

Backlog items do not wait for approval. Each goes to exactly one home, nothing to Jira:

| Item is about | Home |
|---|---|
| a repo standard that a check could enforce (cop, verify step, eval) | the overlay README (`~/Projects/repo-overlays/<Repo>/README.md`), candidate table or open items; it needs a source correction and a baseline before it becomes a trial |
| the orchestration layer (loops, briefs, gates, evidence, trust, dispatch) | `Obsidian/Work/Areas/Engineering Process/Mission Control/MC v2 — Backlog.md`, tagged with its standard |
| skills, hooks, the harness, nightowl, review tooling | `Obsidian/Work/Areas/Engineering Process/Claude Code Improvement Ideas.md` |
| a fact about Will or how he works, or a reference | a memory file, written now |

## 6. Present, then apply on approval

Show the Accepted table with a recommendation per row (apply, drop, or move to backlog) and
the Rejected list with reasons. Wait for Will to pick rows. Then:

- A trivial edit to an existing skill, brief or profile: make it directly. Skills under
  `~/.claude/skills` may be symlinks into `agentic_workflows`; edit through the path, and
  leave the agentic_workflows commit to Will.
- A substantive edit (a new section, more than about ten lines): draft it, show the diff,
  apply on a second yes.
- A new skill: not from one session. Write the method as a page where it was used (the
  overlay README, an Obsidian note) and propose the skill after the second instance.
- `tune description:` rows: reword the description and show before and after.

Run the nightowl brief lint (`lib/nightowl/test/lint.sh` in agentic_workflows) when a coder
template or RULES.md changed.

## 7. Summarize

Short list, no preamble: edits applied (path, one line each), backlog filed (home, one line
each), dropped (one line with the reason). Add a work-log line.
