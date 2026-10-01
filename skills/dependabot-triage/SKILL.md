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
gh pr list --author "app/dependabot" --state open --limit 100 \
  --json number,title,url,createdAt,labels,statusCheckRollup,mergeable,mergeStateStatus \
  --jq '.[] | {number, title, url, createdAt, mergeable, mergeStateStatus,
               ci: ([.statusCheckRollup[]?|select((.conclusion//.state)=="FAILURE")]|length),
               pending: ([.statusCheckRollup[]?|select((.conclusion//.state)|IN("PENDING","IN_PROGRESS","QUEUED"))]|length),
               labels: [.labels[].name]}'
```

**Merge state is separate from CI.** `mergeStateStatus: DIRTY` (with `mergeable: CONFLICTING`) means the branch conflicts with the default branch: a green PR in that state cannot merge, so it never lands in ✅ or 👀. `BLOCKED` usually just means a required review is outstanding, which is normal here (step 6). `UNKNOWN` means GitHub has not computed it yet; re-query.

**Read config from the remote default branch, never the working tree.** The local checkout may be days behind, and a stale manifest or `.github/dependabot.yml` will not match the open PRs:
```bash
git fetch -q origin && git show origin/HEAD:<path>     # or: git show origin/main:<path>
gh api repos/{owner}/{repo}/contents/<path> -H "Accept: application/vnd.github.raw"   # no fetch needed
```

Read the manifest **once** to classify dev vs prod accurately (don't guess from names alone):
- JS: `package.json` → `devDependencies` keys are dev; `dependencies` keys are prod.
- Ruby: `Gemfile` → gems in `group :development`/`:test` are dev.
- **Transitive** (bumped package not in the manifest): find the direct dependency that pulls it in and classify from that parent. Write the remote manifest and lockfile into a scratch dir and run `yarn why <pkg>` (works without `node_modules`) or `npm explain <pkg>`; for a gem, `awk -v g=<gem> '/^    [^ ]/{p=$1} $1==g && /^      [^ ]/{print p}' Gemfile.lock` lists its parents.

Also read `.github/dependabot.yml` from the same remote branch: its `ignore:` list names the majors the repo has deliberately parked (step 4).

## 3. Classify each PR

- **Bump type** — parse the title `Bump <pkg> from A.B.C to D.E.F`: major if A changes, minor if B, patch if C. Grouped PRs (`Bump the <x> group …`, `Bump <a> and <b>`) have no single version — mark as **group** and lean on CI + dev/prod.
- **Dev vs prod** — from the manifest (step 2). Dev-dep bumps are low blast-radius.
- **CI** — `ci > 0` = failing; `ci: 0` and `pending: 0` = green; anything pending (or no checks at all) = awaiting CI, not green. Failing major bumps are the strongest "needs code work" signal.
- **Age** — from `createdAt`. Flag anything > ~30 days as stale.
- **Companion commits** — count the commits someone other than Dependabot pushed onto the PR branch. Use the REST endpoint; `gh pr view --json commits` has under-reported them.
  ```bash
  gh api repos/{owner}/{repo}/pulls/<n>/commits \
    --jq '[.[] | select(.author.login != "dependabot[bot]")] | length'
  ```
  (`{owner}/{repo}` is filled in by `gh` from the current checkout.) Above 0 means someone has pushed a fix onto the branch. A commit whose email is not linked to a GitHub account has a null `author` and is counted too, which is the safe direction.
- **Superseded** — if two or more open PRs bump the *same* package, pick one **vehicle**; the rest are superseded by it.
  - If any of them carries companion commits, the vehicle is the newest PR that does. A bare re-bump without them is superseded even when newer, because it lacks the fix: close it by default (porting the fix onto it is a Phase 2 choice for the user). Never close the PR holding the fix in its favour.
  - Otherwise the vehicle is the newest PR.
  - A superseded PR closes once the vehicle is chosen, whatever its age; the stale threshold does not apply to it.

## 3.5 Security gate (run BEFORE trusting any bucket — especially JS)

Supply-chain attacks in the JS ecosystem are a live threat, and Dependabot's pickup rules reduce but don't eliminate the risk. For each PR's **target** `package@version`, run these cheap checks — no extra tooling needed (uses `gh` + `npm`, already available):

**a) Known advisories — GitHub Advisory DB:**
```bash
gh api graphql -f query='{ securityVulnerabilities(ecosystem: NPM, package: "<pkg>", first: 20) {
  totalCount
  nodes { advisory { summary severity identifiers { type value } }
          vulnerableVersionRange firstPatchedVersion { identifier } } } }'
```
(Ruby gems: `ecosystem: RUBYGEMS`. GitHub Actions bumps: `ecosystem: ACTIONS`, package = the action's `owner/name`, e.g. `actions/checkout`.) If `totalCount` exceeds the nodes returned, raise `first` until it doesn't; long-lived packages can carry more advisories than one page. Interpret against the bump's from→to:
- Target version falls **inside** a `vulnerableVersionRange` → ⚠️ **do not merge**; the bump lands on a still-vulnerable version. → 🔧/hold.
- Current version is vulnerable and target ≥ `firstPatchedVersion` → 🛡️ **security fix — prioritize** (jump it to the top of the merge list).
- Any advisory with identifier type **`MALWARE`** or summary mentioning malicious/compromised → ⚠️ **block and flag loudly**.

**b) Freshness / yank heuristic — `npm view`:** supply-chain payloads ride brand-new or quickly-pulled versions.
```bash
npm view <pkg> time --json | jq -r '.["<target>"]'   # publish date of the target version
npm view <pkg>@<target> deprecated
```
Not `time.modified`: that's when the package as a whole last changed, which only matches the target's publish date when the target is the newest release.
- Target published **< ~7 days ago** → flag for manual eyeball (unusually fresh for a routine bump).
- `deprecated` is set → flag; don't merge onto a deprecated version.

**c) Deeper scanning (optional, stronger — check `command -v osv-scanner`):**
- `osv-scanner` (`brew install osv-scanner`, no account) — scans the lockfile against OSV *including the malicious-packages dataset*. **Recommended low-friction add.** Fetch the PR branch's lockfile without checking the branch out, keeping its real filename (the parser is picked from the name):
  ```bash
  ref=$(gh pr view <n> --json headRefName --jq .headRefName)
  dir=$(mktemp -d)
  gh api "repos/{owner}/{repo}/contents/yarn.lock?ref=$ref" -H "Accept: application/vnd.github.raw" > "$dir/yarn.lock"
  osv-scanner scan -L "$dir/yarn.lock"
  ```
  Swap in `package-lock.json` or `Gemfile.lock` as the repo uses.
- Socket.dev (`socket` CLI / GitHub app) — purpose-built for malicious-package, install-script, and typosquat detection.
If either is present, fold its results in; if neither is, say in the report that the gate ran without a lockfile scan.

Surface security findings at the **top** of the report — a 🛡️ fix or ⚠️ vulnerable/suspicious flag overrides normal bump-type bucketing.

## 4. Sort into action buckets

| Bucket | Rule | Recommended action |
|--------|------|--------------------|
| ✅ **Safe to merge** | CI green, not `DIRTY`, not superseded, **and** (patch bump of any dep **or** minor bump of a **dev** dep) | batch-merge |
| 👀 **Review then merge** | CI green, not `DIRTY`, **and** minor bump of a **prod** dep | eyeball changelog, then merge |
| 🔧 **Needs code work** | **major** bump (even if CI is green), CI red, **or** `DIRTY` with companion commits | draft a ticket — likely needs companion changes (e.g. codegen updates, API migration) |
| 🗑️ **Close** | superseded by a chosen vehicle (any age, see step 3), a major coupled to a parked major, or an abandoned major not worth pursuing | close with a one-line reason |
| ⏳ **Awaiting CI or rebase** | checks pending or absent, or `DIRTY` with no companion commits | re-check later, or offer `@dependabot rebase`; don't merge |

Apply the rules in this order and stop at the first match, so each PR lands in exactly one bucket:
1. A ⚠️ / 🛡️ finding from step 3.5.
2. 🗑️ — superseded, coupled to a parked major, or an abandoned major.
3. ⏳ — checks pending or absent, or `DIRTY` with no companion commits.
4. A vehicle PR carrying companion commits — 🔧 if CI is red or it is `DIRTY` (resolve the conflict by hand), otherwise 👀 whatever the bump type: the code work is already on the branch, so what's left is reviewing it.
5. 🔧 — any other major, or CI red.
6. ✅ / 👀 from the table.

Note: a **major** bump with no companion commits lands in 🔧 regardless of CI — green CI on a major just means tests didn't catch the breakage, not that there is none. It leaves 🔧 only through the verification below, marked in the report.

**Majors coupled to a parked major close, not ticket.** When `dependabot.yml` deliberately ignores a framework's major (parked until the team decides to move) and another package's new major needs that parked major (it targets the framework's next major, or peer-requires it), the bump can't land while the park holds. Close it and propose a matching `ignore:` entry for that package's majors, commented with the parked framework so both lift together — e.g. a utility whose new major targets a newer major of a CSS framework the repo has parked. Confirm the coupling from release notes or peer ranges before closing.

When a 🔧 PR maps to an existing ticket, note that instead of proposing a new one. Cross-check via `jira issue list --project "${JIRA_PROJECT:-YOUR_PROJECT}" -q 'summary ~ "<pkg>" AND statusCategory != Done'`. If `JIRA_PROJECT` is unset, ask for the key rather than searching `YOUR_PROJECT`.

### Preliminary vs verified

The bucketing above is a **fast heuristic** (bump type + CI + dev/prod) — it is NOT proof that a 👀 truly needs review or a 🔧 truly needs code work. Before *acting* on those two buckets, verify against the PR's own evidence:

```bash
gh pr view <n> --json body,files --jq '{body, changed: (.files|length), paths: [.files[].path]}'
```
- Dependabot's `body` carries release notes / changelog / commit list. The **compatibility score** (% of public repos whose CI passed on this update) is not text in the body, only a badge image (URL starts `https://dependabot-badges.githubapp.com/badges/compatibility_score`). To read it, fetch the SVG and pull its text: `curl -sL "<badge url>" | grep -o '<text[^>]*>[^<]*</text>' | sed 's/<[^>]*>//g'`; it may read `unknown`. One input, never a gate: high score + lockfile-only diff can support promoting a 👀 to ✅; a low or unknown score proves nothing alone.
- For a 🔧 **major**: scan the release notes / changelog for `BREAKING`. If nothing breaking touches our usage, it may demote to 👀; if the diff also edits the manifest and many files, 🔧 is confirmed.

Only promote/demote **after looking**, and in the report mark which entries were *verified* vs left at the *heuristic* default — so you know where the confidence is. (For a fast on-call sweep, heuristic-only is fine; before a batch-merge, verify the ✅ candidates.)

## 5. Report (lead with the punchline)

```
📦 DEPENDABOT — <repo> (<N> open)

✅ Safe to merge (<n>):   <#PR pkg A→B (dev/patch)> …            → batch-merge?
👀 Review then merge (<n>): <#PR pkg A→B (prod/minor)> …
🔧 Needs code work (<n>):  <#PR pkg A→B (MAJOR / CI red)> — ticket: <new | existing PROJ-XXXX>
🗑️ Close (<n>):            <#PR pkg — superseded by #M / needs parked <framework> major>
⏳ Awaiting CI or rebase (<n>): <#PR pkg (CI pending / DIRTY)>

Verified: <#PR, #PR>. Everything else is at its heuristic default.
```

Tag an entry a verification moved with where it came from, e.g. `#N pkg A→B (dev/MAJOR, verified, demoted from 🔧)` sitting in 👀. Tag a `DIRTY` PR `conflicts` wherever it lands.

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
- **Never `@dependabot recreate`** a PR that carries companion commits: recreating rebuilds the branch from scratch and discards the fix. If such a PR conflicts with the default branch, resolve the conflict by hand on the branch, or port the fix onto a fresh branch via Phase 2.

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
