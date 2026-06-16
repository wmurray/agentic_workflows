# CONTEXT.md Format

## Location

- **Staging (write here):** `$VAULT/Resources/<Project>/.../CONTEXT.md`
- **Shipped (read-only from this skill):** `<project>/.../CONTEXT.md` in the repo

If a shipped version exists, the staged version is additive — extensions and refinements pending promotion. Do not duplicate terms that already appear in the shipped file unless you're proposing a redefinition (and call that out explicitly).

## Structure

```md
# {Context Name}

{One or two sentence description of what this context is and why it exists.}

## Language

**Order**:
A request by a Customer to purchase a Product.
_Avoid_: Cart, purchase, transaction

**Shipment**:
A single fulfillment event dispatched for one Order.
_Avoid_: Delivery, package

**Customer**:
A person with an account, tracked by ID across the system.
_Avoid_: User (User refers to the authentication account; a Customer may or may not have a User)
```

## Rules

- **Be opinionated.** When multiple words exist for the same concept, pick the best one and list the others as aliases to avoid.
- **Defer to the org glossary.** Never duplicate a term from `org-glossary.md` (or whatever your org's glossary is named). If a project-local term narrows or overlays an org term, say so explicitly (`narrows org-glossary:Customer to ...`).
- **Flag conflicts explicitly.** If a term is used ambiguously, call it out in "Flagged ambiguities" with a clear resolution.
- **Keep definitions tight.** One or two sentences max. Define what it IS, not what it does.
- **Show relationships.** Use bold term names and express cardinality where obvious.
- **Only include terms specific to this project's (or pack's) context.** General programming concepts (timeouts, error types, utility patterns) don't belong even if the project uses them extensively. Before adding a term, ask: is this a concept unique to this context, or a general programming concept? Only the former belongs.
- **Group terms under subheadings** when natural clusters emerge. If all terms belong to a single cohesive area, a flat list is fine.
- **Write an example dialogue.** A conversation between a dev and a domain expert that demonstrates how the terms interact naturally and clarifies boundaries between related concepts.

## Single vs multi-context

Multi-pack projects (e.g. a Rails app using Packwerk) use the multi-context structure:

```
MyApp/
├── CONTEXT-MAP.md
├── docs/adr/                                  ← app-wide decisions
└── packs/
    ├── orders/
    │   ├── CONTEXT.md
    │   └── docs/adr/                          ← pack-specific decisions (rare; usually use app-wide)
    └── customers/
        └── CONTEXT.md
```

`MyApp/CONTEXT-MAP.md` example:

```md
# MyApp Context Map

## Packs with glossaries

- [Orders](./packs/orders/CONTEXT.md) — order lifecycle and fulfillment
- [Customers](./packs/customers/CONTEXT.md) — customer identity and preferences

## Cross-pack relationships

- **Orders → Customers**: Order references a Customer by `customer_id`; pack boundary is enforced via Packwerk
- **Orders ↔ Warehouse (external)**: Order fulfillment triggers a pick-list event in the Warehouse service
```

The skill infers which `CONTEXT.md` applies from the files being discussed. If unclear, ask which pack.

## Single context

One `CONTEXT.md` at the project root. No `CONTEXT-MAP.md` needed.
