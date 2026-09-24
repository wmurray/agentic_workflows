# jira-toolkit

Eleven small, idempotent wrappers for the outward writes an engineering workflow makes
against Jira and GitHub: status moves, the QA and Done transitions, the release-note,
testing-notes and feature-flag fields, sprint membership, assignment, marking a PR ready,
and two guarded merges. Every org value lives in one gitignored file. The safety logic
lives in the scripts, so each one can be allow-listed for unattended use without weakening
the gate.

Mission-control's manual-only actions call these. They also run standalone: the
mission-control seams (the loop guard and the work log) are used when present and skipped
when not.

## Layout

```
env.sh                 sourced by every wrapper: loads jira.env, validates, shared helpers
example.env            the config template — copy to jira.env and fill in
jira.env               your org values (GITIGNORED)
md-to-adf.py           markdown subset → Atlassian Document Format, for the rich-text fields
assign.sh              claim an UNASSIGNED ticket; never reassigns away from a colleague
jira-status.sh         lane → status moves via the CLI (qa/done refused → dedicated wrappers)
qa-transition.sh       REST transition to the QA status, optionally writing testing notes first
done-transition.sh     REST transition to Done with resolution + release note as ADF
release-note.sh        write / verify the release-note field (populate-when-empty; --force)
testing-notes.sh       write the testing-notes field (populate-when-empty; --force)
feature-flags.sh       write / verify the feature-flags labels field
sprint-add.sh          add a ticket to the active sprint
request-review.sh      draft → ready + request the reviewer team (+ outside-sprint label)
merge.sh               guarded PR merge: approved, approval current, CI green, not frozen, no veto label
dependabot-merge.sh    approve + squash Dependabot PRs only, manifest/lockfile-only diffs
test/lint.sh           syntax + arg-handling + config-validation checks, no network
```

Every wrapper takes `--check` (read-only dry run) except `dependabot-merge.sh`, and every
one is a no-op when already in the target state.

## Setup

```bash
cp lib/jira-toolkit/example.env lib/jira-toolkit/jira.env   # then fill it in
export JIRA_API_TOKEN=...                                    # or set it in jira.env
# Optional: expose the wrappers at a stable path for allow-list rules
mkdir -p ~/.claude/lib/pipeline
for f in lib/jira-toolkit/*.sh lib/jira-toolkit/*.py; do ln -sfn "$PWD/$f" ~/.claude/lib/pipeline/; done
```

The wrappers resolve their own location through the symlink, so `env.sh` and `jira.env`
are always found next to the real files. The `jira` CLI (ankitpokhrel/jira-cli), `gh`,
`jq`, `curl` and `python3` must be on PATH.

## Configuration

| Key | Used by | Meaning |
|---|---|---|
| `JIRA_BASE`, `JIRA_LOGIN`, `JIRA_API_TOKEN` | REST wrappers | Site URL and basic-auth identity. The token from the shell environment wins over `jira.env`. |
| `JIRA_KEY_REGEX` | all | What a ticket key looks like. Default matches any `ABC-123`; narrow it to one project if you like. |
| `JIRA_STATUS_READY` `_IN_PROGRESS` `_CODE_REVIEW` `_PRODUCT_REVIEW` `_QA` `_DONE` | jira-status, qa, done | Status names exactly as your workflow spells them. |
| `JIRA_TRANSITION_QA_ID`, `JIRA_TRANSITION_DONE_ID`, `JIRA_DONE_RESOLUTION` | qa, done | Transition ids for the two moves the CLI cannot drive by name. Find them with `GET /rest/api/3/issue/<KEY>/transitions`. |
| `JIRA_FIELD_RELEASE_NOTE`, `JIRA_FIELD_TESTING_NOTES`, `JIRA_FIELD_FEATURE_FLAGS` | field writers, done | Custom field ids. `GET /rest/api/3/field` lists them. The first two are rich text (written as ADF), the third is a labels field. |
| `JIRA_ASSIGNEE_DEFAULT`, `JIRA_ASSIGNEE_DEFAULT_ID` | assign | Who `assign.sh` claims for; the accountId makes the already-assigned check exact. |
| `GH_REVIEW_TEAM` | request-review | Default reviewer team, `org/team`. |
| `GH_OUTSIDE_SPRINT_LABEL`, `GH_SPRINT_LABELS` | request-review, merge | The label meaning "not part of the sprint commitment", and the list merge.sh strips. |
| `GH_BLOCK_LABELS` | merge | Labels that veto a merge, case-insensitive, no override. |
| `GH_MERGE_METHOD` | merge | `squash`, `merge` or `rebase`. |
| `GH_FREEZE_CHECK_PATTERN` | merge | A red CI check whose name matches this is a sprint-freeze gate, bypassed only by `--allow-freeze`. |
| `DEPENDABOT_ALLOWED_PATHS` | dependabot-merge | Regex of files a Dependabot PR may touch. |

`MC_BLOCK_LABELS`, `MC_SPRINT_LABELS` and `MC_FREEZE_CHECK_PATTERN` from a mission-control
profile are honored as overrides for the matching `GH_*` keys.

## Two quirks worth knowing

**Rich-text fields typed as strings.** The release-note and testing-notes fields report
`string` in editmeta but the transition endpoint demands an Atlassian Document, and the
`/issue` PUT accepts one. The writers send ADF first and retry as a plain string on a 400.

**Transitions named "Move to X".** Some issue-type workflows label the forward transition
`Move to <status>` instead of the bare status name. `jira-status.sh` retries once with that
alias before failing.

## Exit codes

`0` done, no-op or check passed · `2` bad arguments · `3` a precondition or verify failed
(merge refused, field empty, release note missing) · `4` refused by design (a lane the
wrapper will not touch, or the loop guard) · `5` a human decision is needed (ticket assigned
to a colleague, no active sprint) · `1` a call failed.
