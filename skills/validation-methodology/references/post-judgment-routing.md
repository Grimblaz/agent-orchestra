# Post-Judgment Routing Notes

This reference pairs the post-judgment prosecution-depth re-activation check with the routing surfaces that follow judgment.

The canonical routing mechanics remain in [review-reconciliation.md](review-reconciliation.md) under `Post-Judgment Fix Routing`; this file keeps the pairing discoverable without duplicating the full routing contract.

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
- `Auto-Tracking`: deferred-significant items create tracking issues automatically after the prevention-analysis advisory.
- `Batch Specialist Dispatch (R4)`: finish all routing decisions first, then batch one dispatch per specialist unless contradictory fix approaches force a split.
- `Post-Fix Targeted Prosecution Pass`: use the R2 post-fix review cycle only after accepted findings are implemented.

Use this file when the caller needs the post-judgment re-activation logic plus a stable pointer to the routing path that follows it.
