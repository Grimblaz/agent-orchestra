# Slate state

Fixture slate state. Shape and rules: `skills/agent-memory-compaction/references/store-records.md`.

Two entries deliberately carry no `critical` row on either polarity — `reference_reused_name` and
`reference_legacy_unknown`. Absent is *unassessed*, not *ordinary*, and the sweep must surface them
to be assessed rather than quietly treat them as ordinary.

<!-- memory-slate-begin -->
2026-06-14 | reference_ordinary_alpha@2026-06-14 | critical | no | ordinary; its recurrence would be visible
2026-06-20 | project_settled_beta@2026-06-20 | critical | no | tracks work that has closed
2026-07-01 | reference_dupe_source@2026-07-01 | critical | no | the survivor carries the same lesson
2026-06-05 | reference_dupe_survivor@2026-06-05 | critical | no | ordinary
2026-06-25 | reference_obsolete_gamma@2026-06-25 | critical | no | ordinary
2026-07-10 | reference_critical_delta@2026-07-10 | critical | yes | catches an otherwise-silent write loss
2026-05-02 | feedback_prerule_epsilon@2026-05-02 | critical | no | ordinary
2026-07-22 | reference_tail_zeta@2026-07-22 | critical | no | ordinary
2026-06-30 | reference_critical_orphan@2026-06-30 | critical | yes | its loss would be expensive and its recurrence invisible
2026-07-05 | reference_interrupted_eta@2026-07-05 | critical | no | ordinary
<!-- memory-slate-end -->
