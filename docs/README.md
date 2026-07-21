# Catalyst — developer documentation

Start here if you're about to change something.

| Document | Read it when |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | You want to know how the app fits together, or what a given feature actually does. Part I is the product overview; Part II is the full feature reference. |
| [`Formrules.md`](Formrules.md) | Before your first non-trivial change. Conventions and invariants — most exist because something broke. |
| [`toAvoid.md`](toAvoid.md) | Before touching scrolling, layout, or anything that felt fine in a preview. Specific mistakes made here already. |
| [`RELEASING.md`](RELEASING.md) | You're cutting a release, or wondering where the update feed and catalogs are hosted. |

## How these are cited

Code comments reference these by name rather than by path, because paths rot and names don't:

```swift
.scrollBounceBehavior(.basedOnSize)   // toAvoid Rule 1
// Extracted rather than written per-view-model (Formrules 12.27)
```

When you hit one of those while reading code, it points here. `Formrules.md` is numbered by part
and rule (`12.27` = Part 12, rule 27); `toAvoid.md` is numbered by rule.

## A note on tone

These documents explain **why**, not what — the diff already says what. Comments and rules that
record a decision, a race that was fixed, or a trap someone already fell into are load-bearing.
Several of them are the only remaining evidence of a bug that took a full session to find.

If you remove one, understand first what it was protecting. If you learn something new the hard
way, add it — that's what keeps these worth reading.
