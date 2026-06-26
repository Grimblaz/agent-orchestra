<!-- markdownlint-disable-file MD041 MD003 -->

# Code-Conductor Orchestration Engagement-Record Detail

Extracted from `agents/Code-Conductor.agent.md` § Process. Detailed read/emit/skip/override/burst/resume semantics for Code-Conductor's `orchestration`-phase engagement records, plus the Named Decisions write-discipline. Load this reference when Code-Conductor resolves the scope-classification gate or reuses a prior orchestration decision.

## Orchestration engagement-record contract

Code-Conductor writes its own decisions to the issue comments under the `orchestration` phase.

- **Read trigger**: Extends Step 0's smart-resume comment scan; it calls `Read-EngagementRecords -IssueNumber {ID} -Phase orchestration` to look for existing orchestration records.
- **Emit trigger**: Immediately after the `scope-classification` gate resolves. Emits the full-state marker to overwrite prior states (latest-comment-wins).
- **Skip behavior**: Direct `/implement {ID}` paths (Copilot-only — Claude does not ship `/implement`) bypass scope-classification and are read-only with respect to the orchestration record (do not emit; may still read for resume-note display). `/code-conductor [text]` prose-routed paths that bypass scope-classification via specialist-dispatch also do not emit. Only flows that actually fire the scope-classification gate emit the burst.
- **Override semantics**: Standard `same-decision-resume` override rules apply. When the engineer shifts choice, Code-Conductor re-fires the gate for the shift-requested decision, carries reused decisions forward, and emits a full revised marker with `recommendation_shift_trigger: engineer-pushback | new-evidence`. Partial re-emit is forbidden.
- **Two-comment burst sequence**: When scope-classification resolves, Code-Conductor posts the comment containing the `<!-- engagement-record-orchestration-{ID} -->` marker and the Markdown mirror first. Immediately after, it posts `<!-- credit-input-orchestration-{ID} -->` carrying:

  ```yaml
  port: orchestration
  adapter: scope-classification
  evidence: "issue #{ID}; scope-classification engagement-record emitted"
  ```

  On engagement-record post-failure, the burst halts immediately and the credit-input marker is NOT posted.
- **Resume-note format**: When `same-decision-resume` reuses a prior orchestration decision, Code-Conductor emits the canonical resume-note format: `Reusing prior {decision_id}: {engineer_choice}` (comma-separated when multiple decisions resume in a session). This applies uniformly with upstream phases per `skills/solution-authoring/SKILL.md` § `resume-note-format` rule.

## Named Decisions write-discipline

Code-Conductor does not author the issue body. The human-readable Named Decisions Markdown mirror is co-located directly inside the comment containing the `<!-- engagement-record-orchestration-{ID} -->` marker payload.

Because the CE Gate evaluation occurs later (under #578), the YAML payload and Markdown mirror are allowed to diverge on the `articulation_text` field:

- The YAML payload MUST carry `articulation_text: ""` (empty string) to prevent premature self-judgment.
- The Markdown mirror MUST carry the literal HTML comment `<!-- CE Gate articulation pending per #578 -->` within its `**Articulation text**` bullet list block to clarify pending status.

> The `#578` issue reference appears in three locations (this bullet, `skills/engagement-record-emission/SKILL.md` D10 guidance, and the canonical Markdown-mirror placeholder used by all engagement-record-emitting agents). If `#578` is renumbered or absorbed, update all three locations as a coordinated sweep.

All other fields (classification, engineer_choice, audit_rationale, etc.) must match field-for-field.
