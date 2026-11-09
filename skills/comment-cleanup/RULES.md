# Comment rules

The one copy of the comment rules. The `comment-cleanup` skill, the mission-control coder
templates, the nightowl pre-push footer, `reply-comments` and the repo overlay's
`bin/verify-comments` all point here. Change the rules in this file, nowhere else.

## The default is no comment

Write code clean as you go and let names, types, extracted methods and assertions carry
the meaning. A comment is kept only when it says a why the code cannot show. Everything
else goes: narration of what a block does, phase markers in scripts and specs, banners,
commented-out code, and justifications for a workaround.

## What survives

- A license or copyright header.
- Behavior forced by an external dependency, platform, vendor or protocol we cannot
  reshape. A surprise in our own code is not a comment: rename, extract or type it so
  the surprise is gone, and leave the symbol flagged for that if the fix is out of scope.
- A YARD docblock on a public boundary method that states a contract the signature
  cannot: a raise the caller should rescue, a nil return that is part of the contract.
  Prefer the signature first: a keyword argument over an option hash, a unit in the name
  over a unit in a tag. Follow the repo's AGENTS.md for the format.
- A lint suppression only when the rule is style-only or faulty. A suppression of a
  correctness or security rule is a bug, not a comment.
- A bare link to an issue, spec or RFC that explains a constraint the code cannot express.

A constraint comment ("do not remove", "talk to X first") is a rule asking to be encoded.
Offer the cheapest cop, type, runtime check or spec, encode it, then delete the comment.

No ticket numbers, PR numbers or change history ("as of", "previously", "now") in a code
or test comment. Describe what the code is, so the comment still reads true after the
ticket closes.

## Format for a comment that survives

One comment per point, directly above the line it explains, one or two sentences, no
prefix tags. If two or more pile up above one call, extract a method whose name carries
the point.

## The comment pass

Run it after review fixes and before every push, by an agent that did not write the diff
when one is available.

1. Scope: only comments this branch adds or edits. List them with
   `git diff <base>...HEAD`, where `<base>` is the branch's base (`origin/main` unless the
   branch stacks on another). Leave older comments in touched files alone.
2. For each one: delete it, replace it with a rename or extract, or keep it under one of
   the survivors above. When unsure whether a survivor applies, delete.
3. List every new lint suppression with its rule. A correctness or security rule fails the
   pass.
4. A changed method signature with an untouched docblock is a finding: update or remove the
   tags.
5. Commit the pass on its own, for example `chore: comment pass`. Skip the commit when
   nothing changed.
6. Rerun the repo's tests and linter. A rename or extract can break either.
