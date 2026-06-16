# ADR Format

## Location

ADRs are drafted in the Obsidian staging area and promoted to the repo only when ready:

- **Staging (write here):** `$VAULT/Resources/<Project>/docs/adr/NNNN-slug.md`
- **Shipped (read-only from this skill):** `<project>/docs/adr/NNNN-slug.md` in the repo

Numbering is sequential: `0001-slug.md`, `0002-slug.md`, etc.

Create the staged `docs/adr/` directory lazily — only when the first ADR is needed.

## Template

```md
# {Short title of the decision}

{1-3 sentences: what's the context, what did we decide, and why.}
```

That's it. An ADR can be a single paragraph. The value is in recording *that* a decision was made and *why* — not in filling out sections.

## Optional sections

Only include these when they add genuine value. Most ADRs won't need them.

- **Status** frontmatter (`proposed | accepted | deprecated | superseded by ADR-NNNN`) — useful when decisions are revisited
- **Considered Options** — only when the rejected alternatives are worth remembering
- **Consequences** — only when non-obvious downstream effects need to be called out

## Numbering

Scan **both** the staged `docs/adr/` and the shipped `docs/adr/` in the repo for the highest existing number, then increment by one. Numbering is per-project (each project starts its own `0001`) and must remain unique across staged + shipped so promotion is just a copy with no renaming.

## When to offer an ADR

All three of these must be true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will look at the code and wonder "why on earth did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If a decision is easy to reverse, skip it — you'll just reverse it. If it's not surprising, nobody will wonder why. If there was no real alternative, there's nothing to record beyond "we did the obvious thing."

### What qualifies

- **Architectural shape.** "The app uses enforced pack/module boundaries." "The write model is event-sourced, the read model is projected into Postgres."
- **Integration patterns between contexts.** "Ordering and Billing communicate via domain events, not synchronous HTTP." Cross-pack or cross-service integration patterns.
- **Technology choices that carry lock-in.** Database, message bus, auth provider, deployment target. Not every library — just the ones that would take a quarter to swap out.
- **Boundary and scope decisions.** "Order data is owned by the orders pack; other packs reference it by ID only." The explicit no-s are as valuable as the yes-s.
- **Deliberate deviations from the obvious path.** "We're using manual SQL instead of an ORM because X." Anything where a reasonable reader would assume the opposite. These stop the next engineer from "fixing" something that was deliberate.
- **Constraints not visible in the code.** "Response times must be under 200ms because of the partner API contract." "We can't do X because of the external compliance requirement."
- **Rejected alternatives when the rejection is non-obvious.** If you considered GraphQL Federation and picked stitching for subtle reasons, record it — otherwise someone will suggest Federation again in six months.
