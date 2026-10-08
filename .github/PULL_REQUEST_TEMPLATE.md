## What changed

<!-- One paragraph. The reason this exists, not a restatement of the diff. -->

## How it was verified

<!--
Paste the commands you ran and what they printed. Exact commands, not "tests
pass". A reviewer who cannot reproduce the claim has to take it on trust, and
trust is what CI is for.

    xcodegen generate
    xcodebuild test -project macterm.xcodeproj -scheme mactermTests -destination 'platform=macOS'
-->

- [ ] The CI checks on this PR are green, and I read them rather than assumed them
- [ ] I ran the project's own checks locally and pasted the output above

## Risk and rollback

<!-- What breaks if this is wrong, and how to undo it. "Revert the commit" is a
rollback plan only when the change has no external effects. -->

- Blast radius:
- Rollback:

## Checklist

- [ ] No secrets, tokens, keys, or `.env` values are in the diff
- [ ] New dependencies are justified in the description, not just added
- [ ] Anything a user can see changed has a screenshot attached
- [ ] Behaviour changes come with a test that fails without them
- [ ] Changes to `project.yml` come with a regenerated `macterm.xcodeproj` — CI builds
      from `xcodegen generate`, so a stale committed project hides a broken spec
- [ ] Changes to `SwiftTermVendor/` are deliberate; it is a local fork, not upstream