---
name: create-pr
description: Creates a pull request in GitHub following a specific template. Supports optional ticket linking — adapt the ticket section to your issue tracker (Linear, Jira, GitHub Issues, etc.).
disable-model-invocation: true
---

# Create PR Skill

This skill creates a GitHub pull request.

Use repository context (current branch, commits, and diffs).
Apply the rules exactly.

Create the PR only after all required follow-up questions have been answered.

After the rule's requirements are satisfied, create the PR using the GitHub CLI (`gh`).

If PR creation is not possible (e.g. missing auth or unpushed branch),
explain why and provide the exact next step to resolve it.

---

## Output Contract (WRITE mode)

When asked to write a PR message, output **Markdown** with this structure:

## PR Title

- Produce a concise, imperative PR title.
- If a ticket number is known, include it in the title:
  "[TICKET-NUMBER]: <short description>"
  Example: "[ENG-123]: Fix foo bug with bars"
- If no ticket exists or was provided, omit the bracketed prefix.

> **Adapting this:** The ticket format defaults to `[PREFIX-NUMBER]`. Change the prefix
> to match your issue tracker (`IMP-` for Linear, `ENG-` or your Jira project key, etc.).

## Summary

- 1–3 sentences describing the problem and how it was addressed.
- Focus on intent, impact, and outcome (the "why"), not implementation minutiae.

## Changes

- A concise bulleted list of **meaningful, user- or system-level changes**.
- Use as many bullets as needed to clearly communicate the scope.
- Group related changes into a single bullet when possible.
- Do NOT list every file, commit, or line-level change.
- Prefer grouping by area (UI / API / DB / Infra) when it improves clarity.

## Notes (optional)

Include only if it adds value (e.g. gotchas, rollout or migration steps, tradeoffs, perf/security impacts, follow-ups).
Omit entirely if none apply.

Style rules:

- Be concise and professional.
- No headings beyond those above.
- No empty sections.

---

## Optional Sections Gate (ASK FIRST)

Before finalizing, ask two questions (do not include sections unless I say yes):

1. "Include a Screenshots section?"
   If yes, append exactly:

   <details><summary>Screenshots</summary>

   </details>

2. "Include a ticket link section?"
   - Prefer inferring the ticket number from the git branch name, if available.
   - Common branch patterns: `prefix/TICKET-123-description`, `TICKET-123-description`
   - If not found, ask for the ticket number.
   - If yes, construct the ticket URL from `$JIRA_BASE_URL` (or your issue tracker's base URL)
     and append:

   ***

   Ticket: [TICKET-NUMBER](<ticket-url>)

   > **Adapting this:** Replace the URL construction with your issue tracker's link format.
   > For Linear: `https://linear.app/YOUR-TEAM/issue/TICKET-NUMBER`
   > For Jira: `https://YOUR-ORG.atlassian.net/browse/TICKET-NUMBER` (set `$JIRA_BASE_URL`)
   > For GitHub Issues: link to `https://github.com/owner/repo/issues/NUMBER`

---

## CREATE Mode: Preflight (before running gh)

> **When applied inline by another skill** (e.g. `/implement`): skip this preflight — the calling skill handles branch push and auth. Jump straight to `gh pr create`.

If asked to actually create the PR with `gh`, perform these checks first. If any fail, STOP and provide the exact fix command(s):

- Auth: `gh auth status`
- Current branch: `git branch --show-current`
- Ensure branch is pushed/upstream exists:
  - If needed: `git push -u origin <branch>`
- Ensure there is a diff vs base (avoid empty PR)

Then create the PR non-interactively:

```bash
gh pr create --title "<TITLE>" --body "<BODY>"
```

If a base branch is required/ambiguous, ask before creating the PR.
