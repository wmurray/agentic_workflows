---
name: dependabot-triage
description: Triage open Dependabot PRs across your repos — classify each by bump type / CI / risk, sort into merge / review / ticket / close buckets, and (on confirmation) batch-merge the safe ones, draft tickets for the ones needing code work, and close stale/superseded ones. Optionally kicks off a fix pipeline for a PR that needs companion changes. Use during on-call weeks or whenever Dependabot PRs pile up.
---

Triage open Dependabot PRs. **Phase 1** (default) is a read-only report + recommended actions; nothing is merged, closed, or ticketed without explicit confirmation. **Phase 2** is an opt-in fix pipeline for PRs that need code changes.

Arguments passed (blank means none): $ARGUMENTS

Dependabot author handle for `gh` is `app/dependabot`.

**Helper scripts.** Snippets that need shell positional parameters live in `scripts/` rather than in this file, because Claude Code substitutes positional placeholders (a dollar sign followed by a digit) everywhere in a skill's text when it's invoked with arguments. All four are read-only (GitHub API and npm registry reads): `gem-parents.sh`, `install-script-config.sh`, `install-script-diff.sh`, `changelog-since.sh`. Call them as `"${CLAUDE_SKILL_DIR}/scripts/<name>.sh"`; one prefix rule covers them, e.g. `Bash("${CLAUDE_SKILL_DIR}/scripts/":*)` or the resolved path, since nothing in that folder writes.

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
  --json number,title,url,createdAt,labels,statusCheckRollup,mergeable,mergeStateStatus,headRefOid \
  --jq '.[] | {number, title, url, createdAt, mergeable, mergeStateStatus, headRefOid,
               ci: ([.statusCheckRollup[]?|select((.conclusion//.state)=="FAILURE")]|length),
               pending: ([.statusCheckRollup[]?|select((.conclusion//.state)|IN("PENDING","IN_PROGRESS","QUEUED"))]|length),
               labels: [.labels[].name]}'
```

`headRefOid` is the head SHA you're triaging; keep it, since the report records it and step 6 checks it before merging.

**Merge state is separate from CI.** `mergeStateStatus: DIRTY` (with `mergeable: CONFLICTING`) means the branch conflicts with the default branch: a green PR in that state cannot merge, so it never lands in ✅ or 👀. `BLOCKED` usually just means a required review is outstanding, which is normal here (step 6). `UNKNOWN` means GitHub has not computed it yet; re-query.

**Read config from the remote default branch, never the working tree.** The local checkout may be days behind, and a stale manifest or `.github/dependabot.yml` will not match the open PRs:
```bash
git fetch -q origin && git show origin/HEAD:<path>     # or: git show origin/main:<path>
gh api repos/{owner}/{repo}/contents/<path> -H "Accept: application/vnd.github.raw"   # no fetch needed
```

Read the manifest **once** to classify dev vs prod accurately (don't guess from names alone):
- JS: `package.json` → `devDependencies` keys are dev; `dependencies` keys are prod.
- Ruby: `Gemfile` → gems in `group :development`/`:test` are dev.
- **Transitive** (bumped package not in the manifest): find the direct dependency that pulls it in and classify from that parent. Write the remote manifest and lockfile into a scratch dir and run `yarn why <pkg>` (works without `node_modules`) or `npm explain <pkg>`; for a gem, `"${CLAUDE_SKILL_DIR}/scripts/gem-parents.sh" <gem> Gemfile.lock` lists its parents.

Also read `.github/dependabot.yml` from the same remote branch: its `ignore:` list names the majors the repo has deliberately parked (step 4).

## 3. Classify each PR

- **Bump type** — major if the first version component changes, minor if the second, patch if the third. A grouped PR (`Bump the <x> group …`, `Bump <a> and <b>`) takes its **largest** member bump, so a group containing a major is a major. The body lists each member as ``Updates `<pkg>` from A to B``; a single-member group or plain bump also names it in the title. This filter reads both:
  ```bash
  gh pr view <n> --json title,body --jq '
    [ (.body | split("\n")[] | rtrimstr("\r") | capture("^Updates `(?<pkg>[^`]+)` from (?<from>\\S+) to (?<to>\\S+)$")),
      (.title | capture("^Bump (?<pkg>\\S+) from (?<from>\\S+) to (?<to>\\S+)")) ]
    | unique_by(.pkg)
    | map(. + {type: ((.from|ltrimstr("v")|split(".")) as $a | (.to|ltrimstr("v")|split(".")) as $b
        | if $a[0] != $b[0] then "major" elif ($a[1]//"0") != ($b[1]//"0") then "minor" else "patch" end)})
    | {bump: (if any(.[]; .type=="major") then "major" elif any(.[]; .type=="minor") then "minor" else "patch" end),
       members: map("\(.pkg) \(.from)→\(.to) (\(.type))")}'
  ```
- **Dev vs prod** — from the manifest (step 2). Dev-dep bumps are low blast-radius. GitHub Actions bumps (`.github/workflows`) are CI tooling: dev-like blast radius, but a major Actions bump is still a major.
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
  - A vehicle on an older target than the bare PR it supersedes is fine; note the newer target as a follow-up bump.
  - Any non-superseded PR carrying companion commits is a vehicle, including a lone PR with no duplicates.
- **Superseded PR with its own fix** — if a superseded PR also carries companion commits, compare its fix with the vehicle's before recommending the close. List each side's non-Dependabot commits, then compare the two fix diffs with lockfiles and snapshot files (`*.snap`, `__snapshots__/`) set aside, since both regenerate and differ for reasons unrelated to the fix:
  ```bash
  gh api repos/{owner}/{repo}/pulls/<n>/commits \
    --jq '.[] | select(.author.login != "dependabot[bot]") | "\(.sha) \(.commit.message | split("\n")[0])"'
  gh api repos/{owner}/{repo}/commits/<sha> -H "Accept: application/vnd.github.diff" \
    | awk '/^diff --git/{skip=(/(yarn\.lock|package-lock\.json|Gemfile\.lock|\.snap|__snapshots__\/)/)} !skip'
  ```
  If the superseded fix touches files the vehicle's doesn't, or changes behaviour the vehicle's leaves alone, the vehicle doesn't cover it. Say in the report whether it's covered; flag it for a human when you can't tell.

## 3.5 Security gate (run BEFORE trusting any bucket — especially JS)

Supply-chain attacks in the JS ecosystem are a live threat, and Dependabot's pickup rules reduce but don't eliminate the risk. For each PR's **target** `package@version`, run these cheap checks — no extra tooling needed (uses `gh` + `npm`, already available):

**First, once per repo — does it run install scripts?** Read the package manager config from the remote default branch:
```bash
"${CLAUDE_SKILL_DIR}/scripts/install-script-config.sh" '{owner}/{repo}'
```
It reads `.yarnrc.yml` (`enableScripts: false`), `.npmrc` and `.yarnrc` (`ignore-scripts`) and prints one line. `{owner}/{repo}` is passed literally; `gh` fills it in from the current checkout.
Report that line once at the top of the security section. Script changes are flagged either way (d), but when scripts run, CI executes them on the PR branch before anyone reviews it — raise a blocking finding before the PR's checks are re-run.

**a) Known advisories — GitHub Advisory DB:**
```bash
gh api graphql -f query='{ securityVulnerabilities(ecosystem: NPM, package: "<pkg>", first: 20) {
  totalCount
  nodes { advisory { summary severity identifiers { type value } }
          vulnerableVersionRange firstPatchedVersion { identifier } } } }'
```
(Ruby gems: `ecosystem: RUBYGEMS`. GitHub Actions bumps: `ecosystem: ACTIONS`, package = the action's `owner/name`, e.g. `actions/checkout`.) If `totalCount` exceeds the nodes returned, raise `first` until it doesn't; long-lived packages can carry more advisories than one page. Interpret against the bump's from→to:
- Target version falls **inside** a `vulnerableVersionRange` → ⚠️ **do not merge**; the bump lands on a still-vulnerable version. → 🔧/hold.
- Current version is vulnerable and target ≥ `firstPatchedVersion` → 🛡️ **security fix — prioritize** (top of 👀; see step 4).
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
- `osv-scanner` (`brew install osv-scanner`, no account) — scans the lockfile against OSV *including the malicious-packages dataset*. **Recommended low-friction add.** A raw scan is mostly noise (a JS lockfile typically carries 50+ pre-existing advisories), so compare each PR's head against its **merge-base** with the default branch: a branch that's merely behind then doesn't show the default branch's later fixes as new findings. Lockfiles are fetched by SHA, not checked out, keep their real filename (the parser is picked from the name), and scans are cached by SHA in one `mktemp` dir per run, so PRs sharing a merge-base scan it once.
  Once per run:
  ```bash
  lock=yarn.lock    # package-lock.json or Gemfile.lock as the repo uses
  cache=$(mktemp -d)
  ```
  Per PR:
  ```bash
  head=$(gh api repos/{owner}/{repo}/pulls/<n> --jq .head.sha)
  base=$(gh api repos/{owner}/{repo}/pulls/<n> --jq .base.ref)
  mb=$(gh api "repos/{owner}/{repo}/compare/$base...$head" --jq .merge_base_commit.sha)
  for sha in "$mb" "$head"; do
    [ -f "${cache:?}/$sha.ids" ] && continue
    mkdir "${cache:?}/$sha"
    gh api "repos/{owner}/{repo}/contents/$lock?ref=$sha" -H "Accept: application/vnd.github.raw" > "${cache:?}/$sha/$lock"
    osv-scanner scan source --format json --verbosity error -L "${cache:?}/$sha/$lock" > "${cache:?}/$sha.json"
    jq -r '.results[]?.packages[]? | .package as $p | .vulnerabilities[]? | "\(.id) \($p.name)@\($p.version)"' "${cache:?}/$sha.json" | LC_ALL=C sort -u > "${cache:?}/$sha.ids"
    rm -f "${cache:?}/${sha:?}/${lock:?}" "${cache:?}/${sha:?}.json"; rmdir "${cache:?}/${sha:?}"
  done
  echo "#<n> triaged head $head, merge-base $mb"
  echo "Malicious on the PR head (blocking):"; grep '^MAL-' "${cache:?}/$head.ids" || echo "  none"
  echo "New versus merge-base:"; LC_ALL=C comm -13 "${cache:?}/$mb.ids" "${cache:?}/$head.ids"
  echo "Fixed versus merge-base:"; LC_ALL=C comm -23 "${cache:?}/$mb.ids" "${cache:?}/$head.ids"
  ```
  At the end of the run:
  ```bash
  rm -f "${cache:?}"/*.ids; rmdir "${cache:?}"
  ```
  Reading it: any `MAL-` ID → ⚠️ block. A **new** ID is something this PR's lockfile introduced, on a package it bumps or pulls in → a finding against the bump, same as a target inside a `vulnerableVersionRange`. IDs on both sides are pre-existing and out of scope; fixed IDs support a 🛡️.
- Socket.dev (`socket` CLI / GitHub app) — purpose-built for malicious-package, install-script, and typosquat detection.
If either is present, fold its results in; if neither is, say in the report that the gate ran without a lockfile scan.

**d) Install scripts:** a new or changed `preinstall` / `install` / `postinstall` runs code at install time — how most npm supply-chain payloads execute. For npm/yarn repos, compare every package version the lockfile adds between the merge-base and the PR head (direct bumps, group members, transitive packages) against the version it replaces. `prepare` is left out: npm runs it only for git and local installs, so check it by hand only for a package resolved from git.
```bash
"${CLAUDE_SKILL_DIR}/scripts/install-script-diff.sh" '{owner}/{repo}' <n>                      # yarn.lock, Yarn 1 or Berry
"${CLAUDE_SKILL_DIR}/scripts/install-script-diff.sh" '{owner}/{repo}' <n> package-lock.json    # npm
```
It prints each package whose install-time scripts differ, with the before/after text, then a one-line count. One `npm view` per changed package, so a large bump (a test-framework major) can take a minute or more — say so rather than appearing to hang. A `package-lock.json` also marks packages with install scripts as `hasInstallScript: true`.

Reading it:
- Any added or changed script → the PR is **low-confidence** (step 4). Show the before/after script text in the report.
- A script that only runs a bundled file (`node postinstall.js`) → read that file from the tarball before judging: `curl -sL "$(npm view <pkg>@<ver> dist.tarball)" | tar -xzO package/<file>`.
- A new script, or the file it runs, that fetches or executes remote code (`curl`, `wget`, `fetch(`, an `http(s)://` URL, `node -e` reaching the network, a base64 blob, any download-then-execute pattern) → ⚠️ **blocking**, same tier as a `MAL-` hit.
- Narrow exception: a native-module package whose script hands off to a well-known prebuilt-binary installer (`napi-postinstall`, `prebuild-install`, `node-pre-gyp`) to fetch its own platform binary is low-confidence, not blocking — name the helper in the report. Anything fetching from elsewhere, or obscuring what it fetches, still blocks.

Surface security findings at the **top** of the report — a 🛡️ fix or ⚠️ vulnerable/suspicious flag overrides normal bump-type bucketing.

## 4. Sort into action buckets

| Bucket | Rule | Recommended action |
|--------|------|--------------------|
| ✅ **Safe to merge** | CI green, not `DIRTY`, not superseded, **and** (patch bump of any dep **or** minor bump of a **dev** dep), with the changelog read done if low-confidence | batch-merge |
| 👀 **Review then merge** | CI green, not `DIRTY`, **and** a minor bump of a **prod** dep, a 🛡️ security fix, or a low-confidence ✅ candidate not yet read | do the changelog read, then merge |
| 🔧 **Needs code work** | **major** bump (even if CI is green), CI red, **or** `DIRTY` with companion commits | draft a ticket — likely needs companion changes (e.g. codegen updates, API migration) |
| 🗑️ **Close** | superseded by a chosen vehicle (any age, see step 3), a major coupled to a parked major, or an abandoned major not worth pursuing | close with a one-line reason |
| ⏳ **Awaiting CI or rebase** | checks pending or absent, or `DIRTY` with no companion commits | re-check later, or offer `@dependabot rebase`; don't merge |

Apply the rules in this order and stop at the first match, so each PR lands in exactly one bucket:
1. A finding from step 3.5. ⚠️ blocks the merge. A 🛡️ security fix goes to the top of 👀, tagged 🛡️, whatever its bump type, and needs the changelog read before it merges; it moves to ✅ only after that read finds nothing concerning. If CI is red or pending, or it's `DIRTY`, it stays where CI and merge state put it, still tagged 🛡️ and listed first there.
2. 🗑️ — superseded, coupled to a parked major, or an abandoned major.
3. ⏳ — checks pending or absent, or `DIRTY` with no companion commits.
4. A vehicle PR carrying companion commits — 🔧 if CI is red or it is `DIRTY` (resolve the conflict by hand), otherwise 👀 whatever the bump type: the code work is already on the branch, so what's left is reviewing it, including the snapshot check below.
5. 🔧 — any other major, or CI red.
6. ✅ / 👀 from the table. A PR that would land in ✅ but is low-confidence (below) goes to 👀 until the changelog read is done.

Note: a **major** bump with no companion commits lands in 🔧 regardless of CI — green CI on a major just means tests didn't catch the breakage, not that there is none. It leaves 🔧 only through the verification below, marked in the report.

**Vehicle snapshot changes must be format-only.** A tool upgrade often rewrites snapshots (a new header line, a serializer that escapes differently) — fine. A snapshot hunk that changes rendered content (an element, attribute or text added or removed) is a possible behaviour change hiding in a regenerated file → flag it for a human. List the snapshot changes in the companion commits, header line dropped:
```bash
gh api repos/{owner}/{repo}/commits/<sha> -H "Accept: application/vnd.github.diff" \
  | awk '/^diff --git/{keep=(/(\.snap|__snapshots__\/)/)} keep && /^[+-]/ && !/^(\+\+\+|---) / && !/^[+-]\/\/ .*[Ss]napshot v/'
```
Line pairs that differ only in quoting or escaping are format-only.

**Majors coupled to a parked major close, not ticket.** When `dependabot.yml` deliberately ignores a framework's major (parked until the team decides to move) and another package's new major needs that parked major (it targets the framework's next major, or peer-requires it), the bump can't land while the park holds. Close it and propose a matching `ignore:` entry for that package's majors, commented with the parked framework so both lift together — e.g. a utility whose new major targets a newer major of a CSS framework the repo has parked. Confirm the coupling from release notes or peer ranges before closing.

When a 🔧 PR maps to an existing ticket, note that instead of proposing a new one. Cross-check via `jira issue list --project "${JIRA_PROJECT:-YOUR_PROJECT}" -q 'summary ~ "<pkg>" AND statusCategory != Done' --plain --no-headers --columns key,status,summary` (`--plain` keeps the CLI from opening its interactive table). If `JIRA_PROJECT` is unset, ask for the key rather than searching `YOUR_PROJECT`. `summary ~` is a text match and returns false hits (a ticket about another app's type-checking for a `typescript` bump), so read each result against the PR before citing it.

### Preliminary vs verified

The bucketing above is a **fast heuristic** (bump type + CI + dev/prod) — it is NOT proof that a 👀 truly needs review or a 🔧 truly needs code work. Before *acting* on those two buckets, verify against the PR's own evidence:

```bash
gh pr view <n> --json body --jq .body
gh api repos/{owner}/{repo}/pulls/<n>/files --paginate --jq '.[].filename'
```
Use the REST files endpoint: `gh pr view --json files` stops at 100 files.
- Dependabot's `body` carries release notes / changelog / commit list. The **compatibility score** (% of public repos whose CI passed on this update) is not text in the body, only a badge image (URL starts `https://dependabot-badges.githubapp.com/badges/compatibility_score`). To read it, fetch the SVG and pull its text: `curl -sL "<badge url>" | grep -o '<text[^>]*>[^<]*</text>' | sed 's/<[^>]*>//g'`; it may read `unknown`. One input, never a gate: high score + lockfile-only diff can support promoting a 👀 to ✅; a low or unknown score proves nothing alone.
- No release notes or changelog in the body → fetch them upstream. Resolve the upstream repo from the registry, look for a GitHub release for the target version, and fall back to the repo's `CHANGELOG.md` (printed from the top down to the current version's entry):
  ```bash
  up=$(npm view <pkg> repository.url | sed -E 's#^(git\+)?(https?|git|ssh)://(git@)?github\.com/##; s#\.git$##')
  gh api "repos/$up/releases?per_page=100" --jq '.[] | select(.tag_name | test("(^|[@v])<target>$")) | .tag_name, .body'
  "${CLAUDE_SKILL_DIR}/scripts/changelog-since.sh" "$up" <current>
  ```
  For a gem, take `owner/repo` from `curl -s https://rubygems.org/api/v1/gems/<gem>.json | jq -r '.source_code_uri // .homepage_uri'`. Use what you find for the breaking-change read and the changelog read below.
- For a 🔧 **major**: scan the release notes / changelog for `BREAKING`. If nothing breaking touches our usage, it may demote to 👀; if the diff also edits the manifest and many files, 🔧 is confirmed.

**The changelog read** — for 🛡️ PRs, minor bumps of prod deps, and low-confidence PRs. Read the notes between the current and target versions for two things only: security notes or advisories, and changes touching high-risk surfaces (auth, sessions/cookies, tokens, crypto, payments, permissions, request handling/CSP). Anything found keeps the PR in 👀 with the finding named; nothing found lets it move to ✅.

A PR is **low-confidence** if any of: compatibility score low or unknown; no release notes even after the upstream fetch; target published within ~7 days (step 3.5b); an added or changed install script (step 3.5d). A low-confidence PR is never in ✅ without the read.

Only promote/demote **after looking**, and in the report mark which entries were *verified* vs left at the *heuristic* default — so you know where the confidence is. (For a fast on-call sweep, heuristic-only is fine, except that a low-confidence PR doesn't reach ✅ without the changelog read.)

## 5. Report (lead with the punchline)

```
📦 DEPENDABOT — <repo> (<N> open)

install scripts: <disabled (enableScripts: false) | RUN on install and in CI>
⚠️  Security (<n>):        <#PR pkg (advisory / MAL- hit / remote-code install script)>
🛡️  Security fixes (<n>):  <#PR pkg A→B, patches <advisory id>>

✅ Safe to merge (<n>):   <#PR pkg A→B (dev/patch)> …            → batch-merge?
👀 Review then merge (<n>): <#PR pkg A→B (prod/minor)> …
🔧 Needs code work (<n>):  <#PR pkg A→B (MAJOR / CI red)> — ticket: <new | existing PROJ-XXXX>
🗑️ Close (<n>):            <#PR pkg — superseded by #M / needs parked <framework> major>
⏳ Awaiting CI or rebase (<n>): <#PR pkg (CI pending / DIRTY)>

Verified: <#PR, #PR>. Everything else is at its heuristic default.
```

Tag an entry a verification moved with where it came from, e.g. `#N pkg A→B (dev/MAJOR, verified, demoted from 🔧)` sitting in 👀. Tag a `DIRTY` PR `conflicts` wherever it lands.

Record each PR's triaged head as `@<short sha>` after its link, so a later head change is detectable (step 6).

Rules: bullets not prose; link each PR `[#N](url)` and ticket `[PROJ-X](url)`; omit empty buckets. Sort 🔧 by risk (majors first). Note the oldest age per bucket so the staleness is visible. Under any PR with an install-script change, show the package, versions, and before/after script text.

## 6. Act — only on explicit confirmation (each action is outward-facing)

Offer the actions; do nothing until you pick. Never merge/close/create-ticket unprompted.

- **Merge ✅ (approve-then-merge)** — there is **no auto-merge configured**; each PR needs an approving review before it can merge. **Never merge the whole ✅ bucket on a single "yes."** Confirm the *specific PR set* first — present the ✅ list and have the user name which to merge (e.g. "all four", "just #5845 and #5849", "skip the prod one"). Only after the set is confirmed, ask which mechanism is preferred:
  - *Skill does it* — run the guarded wrapper, passing each PR with the head SHA recorded at triage (step 5), oldest-first within a package:
    ```bash
    "${MC_PIPELINE:-$HOME/.claude/lib/pipeline}/dependabot-merge.sh" "${SOURCE_DIR:-$HOME/Projects}/<repo>" <n>@<triaged-sha> [<n>@<triaged-sha> ...]
    ```
    It is `lib/jira-toolkit/dependabot-merge.sh` from this toolkit (symlinked into `$MC_PIPELINE`; see `lib/jira-toolkit/README.md`), and the safety logic lives in the script so it can be allow-listed. Per PR, before approving, it requires: author `app/dependabot`, open, not draft, `mergeable` MERGEABLE (it waits out `UNKNOWN`); CI fully green; every changed file, read from the paginated files endpoint, matching `$DEPENDABOT_ALLOWED_PATHS` (manifest/lockfile, from `jira.env`), so GitHub Actions bumps are refused and need a human merge; the head still matching `@<triaged-sha>`; and a merge method the repo allows (`$GH_MERGE_METHOD` if allowed, else the first of squash, merge, rebase). A failed check prints the reason and skips that PR without approving; exit 1 if any PR was skipped. Under the hood: `gh pr review <n> --approve`, then `gh pr merge`; the approval clears the `BLOCKED` (review-required) gate → `CLEAN`.
    When it refuses a PR with "head moved since triage" (Dependabot rebased it after an earlier merge in the batch, or someone pushed), re-run the step 3.5 gate and check CI against the new head, then pass the new SHA. Later PRs in a batch can turn `CONFLICTING` on the lockfile once earlier ones land; comment `@dependabot rebase` on those and rerun once CI is green again.
    Use the full path so a `Bash(<path>:*)` allow rule matches. Don't fall back to raw `gh pr review --approve` / `gh pr merge`: a harness permission classifier may deny them as merging without review, and they skip the wrapper's checks. If the wrapper isn't installed, offer the *Keep the approval human* route instead.
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
