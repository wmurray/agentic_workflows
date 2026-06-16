---
name: strict-refactor-pass
description: Refactor code toward self-documentation — improve naming, extract helpers, reduce branching, introduce domain types. Does not change behavior.
disable-model-invocation: true
---

# Strict Refactor Pass

Task:

- Refactor code to be self-documenting with minimal comments.
- Improve naming; extract helpers; reduce branching; introduce domain types/objects.
- Delete redundant comments.
- Add at most 1–2 inline comments per function, and ONLY for:
  Why / Invariant / Gotcha / Ref / Perf.
- Add TSDoc/YARD ONLY for public boundaries and ONLY for contracts/failure modes.

Safety:

- Do not change behavior unless explicitly requested.
- If behavior is unclear, add/adjust tests first or preserve existing tests.

Output:

- Summarize structural changes (renames, extractions, new types).
- Call out any remaining "sharp edge" comments and what they protect against.
