# Search and merge traps

Incident detail for the lenses in `skills/safe-operations/SKILL.md` § Tooling Lenses. Each section below records one run — the exact search or merge, the artifact it misread, and what caught the error afterwards. The rules a reader applies live in the lens sections named at the top of each entry; nothing here restates them.

## Contents

- [An omitted long line that read as absence](#an-omitted-long-line-that-read-as-absence)
- [A merge that falsified a branch's own justification](#a-merge-that-falsified-a-branchs-own-justification)

## An omitted long line that read as absence

*Cited from § A search result that omits a long matching line reads as absence.*

During `/experience` on issue #591, a grep for `migration|exhaustive|scan` across `skills/plan-authoring/SKILL.md` returned line 309 collapsed to `[Omitted long matching line]`. That line already carried the full migration scan-step enforcement rule — the exact thing the search was looking for.

Reading the result set as it stood, the experience framing went on to claim that plan-authoring has no migration rule. The false-negative was not a missed match; the match was present in the output, rendered as a placeholder that read like context noise.

It survived the experience phase intact. The `/design` standards check caught it, and only because that check re-read the file rather than re-reading the earlier search output.

The same collapsing behavior applies to `[Omitted long context line]` in surrounding context, so a long line adjacent to a real match can be hidden even when the match itself displays. The damage lands hardest on work whose entire purpose is confirming whether something already exists before proposing to build it — the search output there is the evidence for an absence claim, and a placeholder in that output means the evidence was never actually seen.

## A merge that falsified a branch's own justification

*Cited from § A merge of `main` can falsify a factual claim your branch cites, not just collide on a version.*

Issue #1039. The branch added a write-transport section that named `Find-OrUpsertComment` as a forbidden shortcut, and gave as its reason that the function selects its target by a `-like` match which finding text quoting a marker can capture.

While that branch sat in review, #1031 landed on `main` and closed exactly that hazard: selection became line-1-exact via `Test-CommentBodyMarkerLine1`. The merge turned the branch's own stated justification false. The other half of the reasoning — that `-Body` replaces the body verbatim — was still true, so the conclusion "don't use it" survived while its stated reason died. That is the hardest shape to notice, because the sentence still reads correct.

A scoped grep over the branch's own changed files cannot find this class: the falsified text sits inside the diff, while the change that falsified it does not. The trigger is the merge, not the file list.

A second particular from the same merge. #1031's own stale-surface sweep corrected four design documents, three docstrings, and a test comment — and missed `skills/safe-operations/references/git-and-gh-traps.md`, which is the file the write-path guidance actually routes readers to. Citing that trap doc while it was stale would have propagated the closed hazard forward into new work; the correction there was a single line, in a file already open for reading.
