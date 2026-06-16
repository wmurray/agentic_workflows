---
name: comment-cleanup
description: Analyzes changes to code and cleans up unnecessary comments left by agents.
disable-model-invocation: true
---

# Comment Cleanup

Task:

- Remove or rewrite comments that restate what the code does.
- Keep ONLY comments that add non-obvious context:
  Why / Invariant / Gotcha / Ref / Perf.
- Prefer small refactors (rename/extract) over keeping explanatory comments.

Output:

- Summarize which comments were removed and why.
- Ensure remaining comments follow the allowed prefixes and are specific.
