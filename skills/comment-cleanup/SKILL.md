---
name: comment-cleanup
description: Run before pushing a branch. Removes comments in the branch's own diff that restate the code, and keeps only Why/Invariant/Gotcha/Ref/Perf comments.
---

# Comment Cleanup

Task: run the comment pass in [`RULES.md`](RULES.md), next to this file. It holds the
rules (which comments to keep, the five prefixes, the format) and the pass itself (scope
to the branch's own diff, its own commit, then tests and linter again).

Output:

- Summarize which comments were removed or rewritten, and why.
- Confirm every remaining comment in the diff carries one of the allowed prefixes and is specific.
