---
name: dependabot-triage
description: Triage open Dependabot PRs across your repos — classify each by bump type / CI / risk, sort into merge / review / ticket / close buckets, and (on confirmation) batch-merge the safe ones, draft tickets for the ones needing code work, and close stale/superseded ones. Optionally kicks off a fix pipeline for a PR that needs companion changes. Use during on-call weeks or whenever Dependabot PRs pile up.
---

Triage open Dependabot PRs. **Phase 1** (default) is a read-only report + recommended actions; nothing is merged, closed, or ticketed without explicit confirmation. **Phase 2** is an opt-in fix pipeline for PRs that need code changes.

Arguments passed: $ARGUMENTS

Dependabot author handle for `gh` is `app/dependabot`.

**Configuration.** Org values come from env vars set in your shell profile (see the README's Setup section), never from this file:

| Var | Default | Used for |
| --- | --- | --- |
| `SOURCE_DIR` | `$HOME/Projects` | root folder holding your repo checkouts |
| `REPOS` | none; required for the multi-repo count | space-separated repo names under `$SOURCE_DIR` (e.g. one Bundler-based repo and several Yarn/npm repos) |
| `JIRA_PROJECT` | `YOUR_PROJECT` | Jira project key for searching and filing 🔧 tickets |
| `MC_PIPELINE` | `$HOME/.claude/lib/pipeline` | folder holding the `lib/jira-toolkit/` wrappers, including `dependabot-merge.sh` (§6) |

These are the same names `lib/workspace-context.sh` reads, with the same defaults. Do not source that script to get them: it runs its queries and prints JSON. Every command below writes them as `${VAR:-default}` so an unset variable falls back rather than expanding to an empty path.

---

## 1. Scope

The arguments above may name a repo (e.g. `/dependabot-triage MyFrontendApp`). If none was given, run a fast count across all configured repos and ask which to triage in depth — the JS repos can carry 30+ PRs, so **one repo at a time** keeps the report actionable.

```bash
for repo in ${REPOS:?set REPOS to your space-separated repo names}; do
  echo "=== $repo ===" && (cd "${SOURCE_DIR:-$HOME/Projects}/$repo" && gh pr list --author "app/dependabot" --state open --json number --jq 'length' 2>/dev/null)
done
```

If `REPOS` is unset the loop stops with that message; ask the user which repos to count rather than guessing.

## 2. Gather (for the chosen repo)

```bash
cd "${SOURCE_DIR:-$HOME/Projects}/<repo>"
gh pr list --author "app/dependabot" --state open --limit 60 \
  --json number,title,url,createdAt,labels,statusCheckRollup \
  --jq '.[] | {number, title, url, createdAt,
               ci: ([.statusCheckRollup[]?|select((.conclusion//.state)=="FAILURE")]|length),
               labels: [.labels[].name]}'
```

Read the manifest **once** to classify dev vs prod accurately (don't guess from names alone):
- JS: `package.json` → `devDependencies` keys are dev; `dependencies` keys are prod.
- Ruby: `Gemfile` → gems in `group :development`/`:test` are dev.

## 3. Classify each PR

- **Bump type** — parse the title `Bump <pkg> from A.B.C to D.E.F`: major if A changes, minor if B, patch if C. Grouped PRs (`Bump the <x> group …`, `Bump <a> and <b>`) have no single version — mark as **group** and lean on CI + dev/prod.
- **Dev vs prod** — from the manifest (step 2). Dev-dep bumps are low blast-radius.
- **CI** — `ci: 0` = green; `> 0` = failing. Failing major bumps are the strongest "needs code work" signal.
- **Age** — from `createdAt`. Flag anything > ~30 days as stale.
- **Superseded** — if two open PRs bump the *same* package, the older is superseded by the newer.

## 3.5 Security gate (run BEFORE trusting any bucket — especially JS)

Supply-chain attacks in the JS ecosystem are a live threat, and Dependabot's pickup rules reduce but don't eliminate the risk. For each PR's **target** `package@version`, run these cheap checks — no extra tooling needed (uses `gh` + `npm`, already available):

**a) Known advisories — GitHub Advisory DB:**
```bash
gh api graphql -f query='{ securityVulnerabilities(ecosystem: NPM, package: "<pkg>", first: 5) {
  nodes { advisory { summary severity identifiers { type value } }
          vulnerableVersionRange firstPatchedVersion { identifier } } } }'
```
(Ruby gems: `ecosystem: RUBYGEMS`.) Interpret against the bump's from→to:
- Target version falls **inside** a `vulnerableVersionRange` → ⚠️ **do not merge**; the bump lands on a still-vulnerable version. → 🔧/hold.
- Current version is vulnerable and target ≥ `firstPatchedVersion` → 🛡️ **security fix — prioritize** (jump it to the top of the merge list).
- Any advisory with identifier type **`MALWARE`** or summary mentioning malicious/compromised → ⚠️ **block and flag loudly**.

**b) Freshness / yank heuristic — `npm view`:** supply-chain payloads ride brand-new or quickly-pulled versions.
```bash
npm view <pkg>@<target> time.modified version deprecated
```
- Target published **< ~7 days ago** → flag for manual eyeball (unusually fresh for a routine bump).
- `deprecated` is set → flag; don't merge onto a deprecated version.

**c) Deeper scanning (optional, stronger — not installed today):**
- `osv-scanner` (`brew install osv-scanner`, no account) — scans the lockfile against OSV *including the malicious-packages dataset*. **Recommended low-friction add.**
- Socket.dev (`socket` CLI / GitHub app) — purpose-built for malicious-package, install-script, and typosquat detection.
If either is present, run it on the PR branch's lockfile and fold results in.

Surface security findings at the **top** of the report — a 🛡️ fix or ⚠️ vulnerable/suspicious flag overrides normal bump-type bucketing.

## 4. Sort into action buckets

| Bucket | Rule | Recommended action |
|--------|------|--------------------|
| ✅ **Safe to merge** | CI green, not superseded, **and** (patch bump of any dep **or** minor bump of a **dev** dep) | batch-merge |
| 👀 **Review then merge** | CI green **and** minor bump of a **prod** dep | eyeball changelog, then merge |
| 🔧 **Needs code work** | **major** bump (even if CI is green) **or** CI red | draft a ticket — likely needs companion changes (e.g. codegen updates, API migration) |
| 🗑️ **Close** | stale **and** superseded, or an abandoned major not worth pursuing | close with a one-line reason |

Note: a **major** bump always lands in 🔧 regardless of CI — green CI on a major just means tests didn't catch the breakage, not that there is none.

When a 🔧 PR maps to an existing ticket, note that instead of proposing a new one. Cross-check via `jira issue list --project "${JIRA_PROJECT:-YOUR_PROJECT}" -q 'summary ~ "<pkg>" AND statusCategory != Done'`. If `JIRA_PROJECT` is unset, ask for the key rather than searching `YOUR_PROJECT`.

### Preliminary vs verified

The bucketing above is a **fast heuristic** (bump type + CI + dev/prod) — it is NOT proof that a 👀 truly needs review or a 🔧 truly needs code work. Before *acting* on those two buckets, verify against the PR's own evidence:

```bash
gh pr view <n> --json body,files --jq '{body, changed: (.files|length), paths: [.files[].path]}'
```
- Dependabot's `body` carries a **compatibility score** (% of public repos whose CI passed on this update) plus release notes / changelog / commit list. High score + lockfile-only diff → a 👀 may safely promote to ✅.
- For a 🔧 **major**: scan the release notes / changelog for `BREAKING`. If nothing breaking touches our usage, it may demote to 👀; if the diff also edits the manifest and many files, 🔧 is confirmed.

Only promote/demote **after looking**, and in the report mark which entries were *verified* vs left at the *heuristic* default — so you know where the confidence is. (For a fast on-call sweep, heuristic-only is fine; before a batch-merge, verify the ✅ candidates.)

## 5. Report (lead with the punchline)

```
📦 DEPENDABOT — <repo> (<N> open)

✅ Safe to merge (<n>):   <#PR pkg A→B (dev/patch)> …            → batch-merge?
👀 Review then merge (<n>): <#PR pkg A→B (prod/minor)> …
🔧 Needs code work (<n>):  <#PR pkg A→B (MAJOR / CI red)> — ticket: <new | existing PROJ-XXXX>
🗑️ Close (<n>):            <#PR pkg — stale Nd / superseded by #M>
```

Rules: bullets not prose; link each PR `[#N](url)` and ticket `[PROJ-X](url)`; omit empty buckets. Sort 🔧 by risk (majors first). Note the oldest age per bucket so the staleness is visible.

## 6. Act — only on explicit confirmation (each action is outward-facing)

Offer the actions; do nothing until you pick. Never merge/close/create-ticket unprompted.

- **Merge ✅ (approve-then-merge)** — there is **no auto-merge configured**; each PR needs an approving review before it can merge. **Never merge the whole ✅ bucket on a single "yes."** Confirm the *specific PR set* first — present the ✅ list and have the user name which to merge (e.g. "all four", "just #5845 and #5849", "skip the prod one"). Only after the set is confirmed, ask which mechanism is preferred:
  - *Skill does it* — for **each PR in the confirmed set**: `gh pr review <n> --approve` then `gh pr merge <n> --squash`. The approval clears the `BLOCKED` (review-required) gate → `CLEAN`, then the merge goes through. Check a recently-merged Dependabot PR / `gh api repos/<your-org>/<repo> --jq '{squash:.allow_squash_merge,rebase:.allow_rebase_merge,merge:.allow_merge_commit}'` to confirm which merge strategy the repo allows. Merge oldest-first within a package to avoid conflicts.
  - *Native auto-merge* — if the repo has auto-merge enabled in settings, `gh pr merge <n> --squash --auto` queues it to merge automatically once CI passes (a repo-admin setting, off by default — flag this rather than enabling it).
  - *Keep the approval human* — just list the ✅ PRs with direct links to approve + merge in the GitHub UI.
  Default to asking rather than assuming — approving on the user's behalf is an outward-facing action.
- **Tickets for 🔧** — draft each ticket (title `[Deps] Bump <pkg> to <ver>`, body: what breaks, why it needs code, the failing checks). On confirmation create via `jira issue create -tTask -p "${JIRA_PROJECT:-YOUR_PROJECT}" -s "..." -b "..."` (the user may prefer to create them themselves — offer the drafted text either way). Link the ticket back as a comment on the PR if created.
- **Close 🗑️** — `gh pr close <n> --comment "<reason>"`. Dependabot will not reopen unless the dependency updates again.

## 7. Phase 2 — fix pipeline (opt-in, one PR at a time)

For a 🔧 PR to tackle now, offer to run the companion-fix flow:

1. Create (or reuse) the ticket from step 6.
2. Branch off main: `git checkout -b <initials>-<ticket>-bump-<pkg>` (mirror `/implement`'s convention). For parallel work, use a worktree (`git worktree add`).
3. Pull Dependabot's version bump onto the branch (cherry-pick the bump commit or re-apply the manifest/lockfile change).
4. Hand off to **`/implement <ticket>`** for the actual companion code changes (it owns the TDD → review → draft-PR loop). The Dependabot bump becomes the first commit; the fix follows.
5. Once the companion PR is open, close the original Dependabot PR with a pointer to it.

Do this for **one** PR at a time and confirm before each — don't fan out across many bumps autonomously.

---

## Notes for future evolution
- **Trust gate:** validate the bucket classification on a couple of real runs before leaning on batch-merge. If the dev/prod or major-detection is ever wrong, tighten step 3 before automating step 6.
- **Auto-merge:** GitHub native auto-merge (`gh pr merge --auto`) on green CI could retire the ✅ bucket entirely for dev-dep patch/minor — consider once classification is trusted.
