Create a quarterly review note in the Obsidian vault — primarily for performance reviews and career development tracking.

**Vault:** `$VAULT`

If $ARGUMENTS specifies a quarter (e.g., "Q1", "Q1 2026"), use that. Otherwise default to the current quarter.

Quarter boundaries: Q1 = Jan–Mar, Q2 = Apr–Jun, Q3 = Jul–Sep, Q4 = Oct–Dec.

---

## 1. Determine the quarter

```bash
MONTH=$(date +%-m)
YEAR=$(date +%Y)
if [ $MONTH -le 3 ]; then Q=Q1; START="01"; END="03"
elif [ $MONTH -le 6 ]; then Q=Q2; START="04"; END="06"
elif [ $MONTH -le 9 ]; then Q=Q3; START="07"; END="09"
else Q=Q4; START="10"; END="12"
fi
echo "quarter=$Q year=$YEAR start_month=$START end_month=$END"
```

---

## 2. Read source material

Read in this order of preference (most synthesized first):

1. **Monthly reviews** for the quarter's months from `Areas/Career Development/Monthly Reviews/<YYYY>/`
2. **Weekly reviews** from `Areas/Career Development/Weekly Reviews/<YYYY>/` for any weeks in the quarter
3. **Daily notes** directly (as a supplement or fallback) from `Daily Notes/<YYYY>/`

Don't read every daily note individually unless monthly/weekly reviews don't exist — reading ~65 notes is expensive. Use the reviews as the primary source.

---

## 3. Synthesize the quarterly review

This is your primary document for performance reviews. Be thorough on impact and career highlights.

```markdown
---
created: <today's date>
quarter: <YYYY-QX>
---
tags:: [[+Quarterly Reviews]]

# <YYYY> <QX> — Quarterly Review

## Summary
[2–3 sentences capturing the quarter's major themes and arc]

## Projects Owned or Led
- [Project name] — [status and impact]

## Significant Contributions
- [Specific features, fixes, or initiatives with measurable outcomes where possible]

## PRs & Code Output
- [Notable PRs, key technical decisions, architecture choices]

## Cross-Team Impact
- [Work that affected other teams, mentoring, reviews, documentation]

## Wins
- [Biggest accomplishments — use language suitable for a perf review]

## Challenges & Growth
- [What was hard, what you learned from it]

## Skills Developed
- [Technical or non-technical growth this quarter]

## Career Highlights
[These bullets are specifically formatted for use in performance reviews or promotion cases. Be specific and outcome-focused.]
- 
- 

## Goals: Review vs. Reality
- Planned: [from start of quarter if known]
- Achieved: 

## Next Quarter Priorities
- [ ] 
```

---

## 4. Write the review note

Write to: `Areas/Career Development/Quarterly Reviews/<YYYY>/<YYYY-QX>.md`

Full path: `$VAULT/Areas/Career Development/Quarterly Reviews/<YYYY>/<YYYY-QX>.md`

Example: `…/Quarterly Reviews/2026/2026-Q2.md`

---

## 5. Confirm

Report where the note was written. Ask: "Is there anything about impact or outcomes you want added or sharpened for the career highlights section?"
