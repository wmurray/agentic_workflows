# Comment rules

The one copy of the comment rules. The `comment-cleanup` skill, the mission-control coder
templates, the nightowl pre-push footer and `reply-comments` all point here. Change the
rules in this file, nowhere else.

## What a comment may say

Keep a comment only when it adds context the code cannot carry. Start it with one of
these prefixes:

- `Why:` the reason for a choice a reader would otherwise question.
- `Invariant:` a condition the code relies on and does not check.
- `Gotcha:` a trap: an ordering, a side effect, a library quirk.
- `Ref:` a link to a spec, an RFC or an upstream issue that explains the code.
- `Perf:` why the code is shaped for speed or memory over plainness.

Remove every comment that restates what the code does. When a comment explains what a
block does, prefer a rename or an extracted method whose name says it, and drop the
comment.

No ticket numbers, PR numbers or change history ("as of", "previously", "now") in a code
or test comment. Describe what the code is, so the comment still reads true after the
ticket closes.

## Format

- One comment per point, directly above the line or argument it explains.
- At most one prefixed comment per block. If three or more would pile up above one call,
  extract a method so its name carries one of them.
- One prefix per short paragraph. Two points under one prefix are two comments.

## The comment pass

Run it after review fixes and before every push.

1. Scope: only comments this branch adds or edits. List them with
   `git diff <base>...HEAD`, where `<base>` is the branch's base (`origin/main` unless the
   branch stacks on another). Leave older comments in touched files alone.
2. Apply the rules above to each one: keep it with the right prefix, rewrite it, replace
   it with a rename or extract, or delete it.
3. Commit the pass on its own, for example `chore: comment pass`. Skip the commit when
   nothing changed.
4. Rerun the repo's tests and linter. A rename or extract can break either.
