# Post-Judgment Routing Notes

This reference pairs the post-judgment prosecution-depth re-activation check with the routing surfaces that follow judgment.

The canonical routing mechanics remain in [review-reconciliation.md](review-reconciliation.md) under `Post-Judgment Fix Routing`; this file keeps the pairing discoverable without duplicating the full routing contract.

## Post-Judgment Disposition Gate (AC1, AC2, AC10)

Before any fix routing or re-activation detection, run the review-disposition engagement gate per `skills/review-judgment/SKILL.md § Post-Judge Disposition Gate`. This gate fires in the owning parent workflow after the judge-rulings comment is confirmed written.

**Gate scope**: Judge-sustained findings only (`judge_ruling: sustained`). Defense-sustained findings skip the gate.

**Direct review path** (`/orchestra:review`, `/orchestra:review-judge`): the gate fires immediately after the judge-rulings comment per the commands' Post-judgment disposition gate steps.

**GitHub review path** (`/review-github`, `code-review-intake/SKILL.md` Step 5): `skills/code-review-intake/references/response-loop-completion.md` step 1 is the sole executor of the disposition gate on this path — it already ran the gate for the proxy-prosecution judge pass before this bullet is reached. This is the AC10 Code-Conductor pre-dispatch check: it does not fire the gate a second time; it verifies/confirms the gate already ran at the step-1 site before any specialist dispatch. If the incoming context carries a `<!-- judge-rulings ... -->` block, confirm the corresponding `<!-- review-dispositions-{PR} -->` and `<!-- engagement-record-review-{PR} -->` markers were persisted by step 1 — this check fires even on a zero-sustained judge pass, since step 1 emits both markers (with `entries: []` on the dispositions marker) whether or not any finding was sustained.

**Ordering invariant**: disposition gate → re-activation detection → fix routing. The gate records engineer intent before fix routing begins; re-activation detection and batch-dispatch (R4) follow.

## Post-Judgment Re-Activation Detection

After the judge emits rulings, check sustained findings against the prosecution depth map recorded during Prosecution Depth Setup.

**Scope**: Apply only to main-review findings (`review_stage: main`). Post-fix prosecution (`review_stage: postfix`) always runs at full depth - a sustained finding in a depth-reduced category during post-fix does not signal a calibration miss.

1. For each sustained finding (judge ruling: `sustained` or `finding-sustained`; `sustained` = judged findings; `finding-sustained` = express-lane findings), check if its `category` was at `light` or `skip` depth.
2. If a sustained finding was in a lightened/skipped category, write a re-activation event:

   ```powershell
   pwsh -NoProfile -NonInteractive -File skills/calibration-pipeline/scripts/write-calibration-entry.ps1 -ReactivationEventJson '{"category": "{cat}", "triggered_at_pr": {pr_number}, "expires_at_pr": {pr_number + 5}, "trigger_source": "code_prosecution"}'
   ```

3. Log: `"Re-activation triggered for {category} - sustained finding at {depth} depth (persists for 5 PRs)"`.
4. Increment `prosecution_depth_reactivations` in pipeline metrics by 1 for each event written.
5. If no depth map was recorded (prosecution depth setup skipped or failed), skip this check silently.

## Post-Judgment Routing Index

After judgment, pair the re-activation check above with the routing mechanics in [review-reconciliation.md](review-reconciliation.md):

- `AC Cross-Check Gate`: acceptance-criteria violations cannot remain deferred or rejected.
- `Auto-Tracking`: deferred-significant items route through the Filing Approval Gate (§2e) before filing, after the prevention-analysis advisory.
- `Batch Specialist Dispatch (R4)`: finish all routing decisions first, then batch one dispatch per specialist unless contradictory fix approaches force a split.
- `Post-Fix Targeted Prosecution Pass`: use the R2 post-fix review cycle only after accepted findings are implemented.

Use this file when the caller needs the post-judgment re-activation logic plus a stable pointer to the routing path that follows it.
