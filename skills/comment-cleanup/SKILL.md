---
name: comment-cleanup
description: Analyzes changes to code and cleans up unnecessary comments left by agents.
disable-model-invocation: true
---

# Comment Cleanup

> **Note:** This skill is `disable-model-invocation`. It cannot be called with `/comment-cleanup` from inside another skill: read the file and apply its rules directly.

Task: run the comment pass in [`RULES.md`](RULES.md), next to this file. It holds the
rules (which comments to keep, the five prefixes, the format) and the pass itself (scope
to the branch's own diff, its own commit, then tests and linter again).

Output:

- Summarize which comments were removed or rewritten, and why.
- Confirm every remaining comment in the diff carries one of the allowed prefixes and is specific.
