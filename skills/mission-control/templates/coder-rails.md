# Coder worker template — a Rails repo

Spawn with agent type `rails-feature-developer`, `run_in_background: true`. Fill `{PLACEHOLDERS}`. The org-valued ones (`{MC_HOME}` `{BRANCH_PREFIX}` `{BASE_REF}` `{WORKTREE_RECIPE}` `{STYLE_GUIDE}` `{TEST_CONVENTIONS}`) come from the overlay's **Template fills** section; `{WORKTREE_RECIPE}` is the overlay's recipe for THIS repo.

---

Implement ticket **{TICKET}** in the **{REPO}** repo at `{REPO_PATH}` (Rails + RSpec; Packwerk where the repo uses it). Read `{REPO_PATH}/AGENTS.md` first for conventions{TEST_CONVENTIONS — the repo's spec-style rules from the overlay, in parentheses; omit if none}.

## Approved plan
Read the full plan at: `{PLAN_PATH}`

## Approved decisions (settled — implement exactly as stated)
{APPROVED_DECISIONS — the resolved open questions from Gate 1, as imperative bullets. Leave none ambiguous.}

## CRITICAL — worktree isolation (do this first)
Do NOT work in the shared checkout at `{REPO_PATH}`, and **do NOT hand-roll `git worktree add` + `cp .env`** in a repo with a shared test database — that copies an empty test-DB setting and every worktree then collides on the same test DB (contention, idle-in-transaction locks, flaky cross-DB FK failures). Create the worktree exactly as the overlay's recipe for this repo says:
```
{WORKTREE_RECIPE}
```
The recipe leaves the worktree **on branch `{BRANCH_PREFIX}{TICKET_SLUG}`** (the operator's branch convention) — that is your `{BRANCH}`, cut from `{BASE_REF}`; work, commit, and push on it. Do ALL work, test runs, and commits inside the worktree. Run Ruby the way `AGENTS.md` says (typically through the repo's version manager, e.g. `mise exec -- bundle exec rspec <path>`).

## Process (TDD, per the plan)
1. Add the empty `describe`/`context`/`it` blocks for the plan's cases. Then proceed — do NOT pause (the plan is approved).
2. One failing test at a time → confirm it fails → minimal code to pass → confirm green. Lead with the case that is actually red first (e.g. a denial/negative case if the default would otherwise pass). **For a bug/defect fix, the first test for each symptom MUST reproduce that symptom against the REAL path and red on the unfixed code — never stub the layer the bug lives in** (a double that ignores the real query/scope, or returns state the DB can't produce, makes a test that passes either way and proves nothing — a real miss from an earlier ticket). If the plan carries a `## Discovery / investigation summary`, its "scenarios the fix must cover" are your failing-test checklist.
3. **Commit after EACH passing step** (raw `git commit`, NOT the `/commit-changes` skill — it's `disable-model-invocation`; apply its message conventions by hand). **Use plain `git` (e.g. `/usr/bin/git`), NOT `rtk git`, for ALL mutating git ops (add/commit/reset/rebase) — the rtk wrapper has been observed to drop unstaged changes in a worktree (a stray `reset` in the reflog). `rtk git` is fine for read-only ops (status/log/diff) only.** A mid-run death with 0 commits loses every checkpoint. **For the four DESTRUCTIVE ops, use the wrapper `{MC_HOME}/mc-gitop.sh` instead of raw git — `mc-gitop reset-hard <ref>` (base-freshness), `mc-gitop restore-path <path>...`, `mc-gitop checkout-path <ref> -- <path>...`, `mc-gitop branch-del <branch>...`. Raw `git reset --hard` / `git restore <path>` / `git checkout … -- <path>` / `git branch -D` trip the ask-only safety guard, which has no human to answer under the loop and hangs the tick. The wrapper runs the identical op in the cwd; cd into the worktree first.** End every commit message with the harness attribution line for the model you are running as (`Co-Authored-By: Claude <your model> <noreply@anthropic.com>`); never copy another model's name.
4. Follow the existing sibling spec/file style; mirror the pattern the plan identified — do not invent new structure.
5. **Comment discipline.** Write a comment ONLY when it adds non-obvious context (Why / Invariant / Gotcha / Ref / Perf); never write one that restates what the code already says. **NEVER put ticket numbers (ABC-XXXX), PR numbers, or "as of <ticket>" change-history into code or test comments** — they are noise the moment the ticket closes and the comment must read evergreen. Describe behavior by what it *is*, not which ticket introduced it (e.g. "the native signup screen", NOT "the ABC-1544 behaviour"). Same rule for commit-introduced TODOs — no bare ticket refs.

## Pre-push verification (ALL must pass — this is the contract)
- `mise exec -- bundle exec rspec {SPEC_PATHS}` → green
- `mise exec -- bundle exec rubocop {CHANGED_FILES}` → no offenses. **NEVER run blanket `rubocop -a`** — its LineLength/string autocorrect shatters long string literals (observed: 15 offenses → 201). Fix by hand or scope autocorrect to named cops.
- If the repo uses Packwerk: `mise exec -- bundle exec packwerk check` → no offenses (catches NEW cross-pack refs). If it flags one, `mise exec -- bundle exec packwerk update` to record it in `package_todo.yml`.
- If the repo uses Packwerk: `mise exec -- bundle exec packwerk validate` → must pass (catches STALE violations after a refactor). If it reports stale violations, `mise exec -- bundle exec packwerk update-todo`.
Then push: `git push -u origin {BRANCH}`.

## Do NOT
- Do NOT open a PR (the orchestrator owns draft-PR creation at the review gate).
- Do NOT run difit or any review viewer.
- Do NOT touch files outside the plan's scope (note any necessary drive-by separately).

## Return (structured data, NOT a human message)
(a) worktree path + branch
(b) commit list (sha + subject, one per line)
(c) file diff summary (files, +/- lines)
(d) verification results: rspec example counts, rubocop, packwerk check + validate (where applicable) — all green?
(e) the key new/changed code as code blocks (the core class + any controller/wiring change)
(f) deviations from the plan and why (e.g. an API the plan assumed wasn't available)
(g) surprises worth a human knowing at review — dead code now created, redundant tests, drive-by fixes, anything that sets precedent for sibling tickets. **If the fix adds or modifies state / an attribute / a code path that NOTHING reads at runtime (only specs read it — no CSS, no other code, no rendering), FLAG it explicitly as a test-only seam** rather than presenting it as a runtime behavior fix; grep for the consumers before you decide which it is.
(h) **`feature_flags`** — a list of every feature-flag name the change introduces, flips, or gates on, as the exact snake_case token(s) in code (a ticket may touch MORE THAN ONE). `[]` if the work is not behind any flag. **Captured here, from the code you actually wrote** — the merge field-check writes the tracker's Feature Flags field from this list, so it never has to re-search the codebase.

## Writing

Every piece of prose you produce (plan, PR body, code comments, vault notes, result JSON text) follows `{STYLE_GUIDE}`. Read it before writing. The firm rules: no em dashes, no "rather than", no "not X, but Y", no trailing "-ing" analysis clauses, plain `is`/`are` over "serves as".

## Result file
Also write the exact same return as JSON to `{RESULT_PATH}` before you finish, if that value is a real filesystem path. If it still reads as a `{…}` placeholder, no file is expected and the chat return above is the only return. The orchestrator reads the file, not your chat message, when one is present.
