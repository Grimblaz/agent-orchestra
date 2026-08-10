# Compaction Lens Exhibits

Incident detail for the lenses in `skills/agent-memory-compaction/SKILL.md` § Compaction Lenses. The section below records one sweep — what was moved, which checks reported clean, and which cross-check fired. The rule a reader applies lives in the lens section named at the top of the entry, not here.

## Contents

- [Five entries with a ledger record and a live pointer](#five-entries-with-a-ledger-record-and-a-live-pointer)

## Five entries with a ledger record and a live pointer

*Cited from § Relocating a line to preserve one subject silently preserves every other subject on it.*

Issue #1019's first memory-store sweep. Two entries filed under settled sections turned out to have open issues, so their pointer lines were re-homed to the active section. One of those lines carried three linked subjects and the other carried four. For five of those seven subjects the recorded disposition was `demote`, not keep — so the relocation that rescued the two live subjects carried the five demoted ones along with it.

The resulting state was five entries that simultaneously held an executed ledger record, an archive line, and a live pointer in the index: the incomplete-disposition state the record-before-act ordering exists to make visible.

Every aggregate check passed. The index was under budget. The checker returned `RESULT: clean` with exit 0, 0 hookless subjects, and 0 unattributed notes. The partition check returned `unaccounted: 0`. None of those instruments can see this state — the strays are lawful pointers with intact hooks, and the partition asks only whether anything left *without* a record, never whether everything carrying a record actually left. The counts agreed as well: 77 records against 77 intended exits, while five of those exits had not happened.

What caught it was a set-equality cross-check run in both directions and against the archive. The leg that fired was removal-authorizing dispositions still present in the index, which should have been 0. The other two legs — keep-hot entries missing from the index, and demoted subjects missing from the archive — were also run.
