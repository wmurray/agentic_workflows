# Coder worker template — a TypeScript repo

Spawn with agent type `typescript-developer`, `run_in_background: true`. Fill `{PLACEHOLDERS}`. The org-valued ones (`{MC_HOME}` `{BRANCH_PREFIX}` `{BASE_REF}` `{STYLE_GUIDE}`) come from the overlay's **Template fills** section.

---

Implement ticket **{TICKET}** in the **{REPO}** repo at `{REPO_PATH}` ({STACK — e.g. React Native + Expo + TypeScript}). Read `{REPO_PATH}/AGENTS.md` first for conventions.

## Approved plan
Read the full plan at: `{PLAN_PATH}`

## Approved decisions (settled — implement exactly as stated)
{APPROVED_DECISIONS — the resolved open questions from Gate 1, as imperative bullets. Leave none ambiguous.}

## CRITICAL — worktree isolation (do this first)
Do NOT work in the shared checkout. Create your own worktree:
```
cd {REPO_PATH}
git fetch origin
git worktree add -b {BRANCH_PREFIX}{TICKET_SLUG} ../{REPO_LOWER}-wt-{TICKET_SLUG} {BASE_REF}   # branch convention: {BRANCH_PREFIX}<TICKET> (that is your {BRANCH})
cd ../{REPO_LOWER}-wt-{TICKET_SLUG}
```
Do ALL work, test runs, and commits inside the worktree. If the worktree needs install/build artifacts the repo gitignores, bootstrap them before running tests (note what you copied/installed in your return).

## Process (TDD, per the plan)
1. Scaffold the empty `describe`/`it` blocks for the plan's cases. Then proceed — do NOT pause (the plan is approved).
2. One failing test at a time → minimal code to pass → confirm green. Mind the gotchas the plan flagged (mock setup, fire-and-forget async needing `waitFor`, timer behavior, etc.). **For a bug/defect fix, the first test for each symptom MUST reproduce that symptom against the REAL path and red on the unfixed code — never stub the layer the bug lives in** (a mock that ignores the real server filter, or a read policy replacing the network, makes a test that passes either way and proves nothing — a real miss from an earlier ticket). If the plan carries a `## Discovery / investigation summary`, its "scenarios the fix must cover" are your failing-test checklist.
3. **Commit after EACH passing step** (raw `git commit`, NOT the `/commit-changes` skill — it's `disable-model-invocation`; apply its conventions by hand). **Use plain `git` (e.g. `/usr/bin/git`), NOT `rtk git`, for ALL mutating git ops (add/commit/reset/rebase) — the rtk wrapper has been observed to drop unstaged changes in a worktree (a stray `reset` in the reflog). `rtk git` is fine for read-only ops (status/log/diff) only.** **For the four DESTRUCTIVE ops, use the wrapper `{MC_HOME}/mc-gitop.sh` instead of raw git — `mc-gitop reset-hard <ref>` (base-freshness), `mc-gitop restore-path <path>...`, `mc-gitop checkout-path <ref> -- <path>...`, `mc-gitop branch-del <branch>...`. Raw `git reset --hard` / `git restore <path>` / `git checkout … -- <path>` / `git branch -D` trip the ask-only safety guard, which has no human to answer under the loop and hangs the tick. The wrapper runs the identical op in the cwd; cd into the worktree first.** End every commit message with the harness attribution line for the model you are running as (`Co-Authored-By: Claude <your model> <noreply@anthropic.com>`); never copy another model's name.
4. Follow the existing sibling component/spec style; mirror the pattern the plan identified.
5. **Comment discipline.** Write a comment ONLY when it adds non-obvious context (Why / Invariant / Gotcha / Ref / Perf); never write one that restates what the code already says. **NEVER put ticket numbers (ABC-XXXX), PR numbers, or "as of <ticket>" change-history into code or test comments** — they are noise the moment the ticket closes and the comment must read evergreen. Describe behavior by what it *is*, not which ticket introduced it (e.g. "the native signup screen", NOT "the ABC-1544 behaviour"). Same rule for any TODO — no bare ticket refs.

## Pre-push verification (ALL must pass)
- Run the project's test command for the affected specs → green (note iOS + Android if RN).
- **If you changed a SHARED/design-system component or a behavior other code depends on** (e.g. `BackButton`, a hook, a context, a util), the changed-file specs are NOT enough — a behavior change there silently breaks CONSUMER specs that aren't in your diff. Grep for every consumer of the changed interaction (`grep -rl "<BackButton" __specs__ app`, etc.) and run that wider — but still bounded — set in ONE invocation before pushing. CI runs the full suite; do not let it be the first thing to exercise consumers you altered.
- Type-check (`yarn tsc --noEmit` or the project's script) → no NEW errors (pre-existing errors in unrelated files are fine; report the count).
- `yarn lint` on the changed files → clean. Do NOT run a blanket lint/format that rewrites unrelated files.
Then push: `git push -u origin {BRANCH}`.

## Do NOT
- Do NOT open a PR (the orchestrator owns draft-PR creation at the review gate).
- Do NOT run difit or any review viewer.
- Do NOT touch files outside the plan's scope (note any necessary drive-by separately).

## Return (structured data, NOT a human message)
(a) worktree path + branch
(b) commit list (sha + subject, one per line)
(c) file diff summary (files, +/- lines)
(d) verification results: test counts (iOS/Android if applicable), type-check (new vs pre-existing errors), lint — all green?
(e) deviations from the plan and why
(f) surprises worth a human knowing at review — dead code now created, redundant tests, alerting/monitoring that may go silent, anything reviewers should confirm. **If the fix adds or modifies state / an attribute / a code path that NOTHING reads at runtime (only specs read it — no CSS, no other code, no rendering), FLAG it explicitly as a test-only seam** rather than presenting it as a runtime behavior fix; grep for the consumers before you decide which it is.
(g) **`feature_flags`** — a list of every feature-flag name the change introduces, flips, or gates on, as the exact token(s) in code (a ticket may touch MORE THAN ONE). `[]` if not behind any flag. **Captured here, from the code you actually wrote** — the merge field-check writes the tracker's Feature Flags field from this list, so it never has to re-search the codebase.

## Writing

Every piece of prose you produce (plan, PR body, code comments, vault notes, result JSON text) follows `{STYLE_GUIDE}`. Read it before writing. The firm rules: no em dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are` over "serves as".

## Result file
Also write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real filesystem path. If it still reads as a `{…}` placeholder, no file is expected and the chat return above is the only return. The orchestrator reads the file, not your chat message, when one is present.
