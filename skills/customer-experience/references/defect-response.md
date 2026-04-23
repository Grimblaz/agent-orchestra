# Customer Experience Gate Defect Response

This reference owns the CE Gate remediation and degradation rules extracted for the customer-experience composite.

See [orchestration-protocol.md](orchestration-protocol.md) for surface routing, scenario execution, intent scoring, and PR-body output requirements.

## Two-Track Defect Response

When a functional defect or intent deficiency is found:

**Track 1 - Default remediation (fix in-PR; follow-up issue allowed when new design decision is required):**

- Route to Code-Smith (implementation defect) or Test-Writer (test gap) with scenario failure evidence
- Require regression test for the defect
- Re-exercise the failing scenario after fix
- Loop budget: **2 fix-revalidate cycles maximum**, then escalate via `#tool:vscode/askQuestions` with options: "Retry with different approach", "Skip CE Gate with documented risk", "Abort and investigate manually"

**Intent deficiencies (partial or weak intent match)** also route through Track 1: route to Code-Smith with the specific rubric criterion violated and the design intent reference from the `[CE GATE]` step's `Design Intent` field (falling back to the latest durable `<!-- design-issue-{ID} -->` handoff comment, then to the issue body if no durable handoff exists). Platform-local design caches may be used as an optimization when available, but they are not required. When the deficiency requires a new design decision before a fix can be defined (e.g., the core interaction model contradicts the design intent rather than merely being under-polished), Code-Conductor may instead create a follow-up issue with rationale - this is a judgment call, not automatic; the default is to fix in-PR. When taking the follow-up issue path, still invoke Track 2 before PR creation and log the outcome in the PR body.

**Track 2 - Systemic analysis (always, after Track 1 fix is complete or when taking the follow-up-issue path):**

- Call Process-Review subagent with: the defect description, what scenario revealed it, and which agent/file/instruction likely caused the gap
- Process-Review will emit a structured CE Gate Defect Analysis (gap description, affected agent/file, recommended fix, ready-to-use issue title + body) - if a systemic gap is confirmed, **Code-Conductor creates the issue** using Process-Review's ready-to-use title and body; Process-Review does not create GitHub issues itself
- If a systemic gap is confirmed: before creating the follow-up GitHub issue, apply the prevention-analysis advisory from `skills/safe-operations/SKILL.md` §2d. Then create the follow-up issue in the agent-orchestra repository (or fallback to current repo with label `process-gap-upstream`)
- `No systemic gap found` is a valid Process-Review outcome - log it in the PR body
- Track 2 is non-blocking: do not hold up Track 1 fix or PR creation

**Intent deficiency analysis**: Process-Review also handles intent mismatches (where the implementation is functionally correct but design intent was not achieved). Provide the intent mismatch description alongside the rubric criterion violated.

## Graceful Degradation

- If native browser tools are unavailable for a Web UI surface (verify `workbench.browser.enableChatTools: true` is set in `.vscode/settings.json`): try Playwright MCP as fallback; if still blocked, emit `⚠️ CE Gate skipped - browser tools unavailable` and continue
- If the dev environment is not running and cannot be started: emit `⚠️ CE Gate skipped - dev environment unavailable` and continue
- For any surface type, if the designated tool cannot be invoked after one retry: emit `⚠️ CE Gate skipped - {surface} tool unavailable ({reason})` and continue
- Skipped CE Gates must be noted in the PR body with the skip reason

## CE and Proxy Prosecution Re-Activation

When CE prosecution or GitHub proxy prosecution produces sustained findings:

**Scope**: CE findings use `review_stage: ce`; proxy findings use `review_stage: proxy`. Both stages run at actual (not depth-reduced) depth, so a sustained finding in a depth-reduced category is a genuine calibration signal - the re-activation trigger is correct for these stages.

1. Map the finding's category to the prosecution depth map. For findings with `category: n/a`, infer category using keyword heuristics:
   - Security keywords (auth, token, secret, permission, injection, XSS, CSRF) -> `security`
   - Performance keywords (latency, cache, memory, slow, timeout, N+1) -> `performance`
   - Architecture keywords (dependency, coupling, layer, boundary, import cycle) -> `architecture`
   - Pattern keywords (convention, naming, style, consistency) -> `pattern`
   - Ambiguous -> re-activate ALL matching categories
2. If the inferred or declared category was at `light` or `skip` depth, write a re-activation event with `trigger_source: "ce_prosecution"` or `"github_proxy"` respectively
3. Follow the same `write-calibration-entry.ps1 -ReactivationEventJson` call pattern as code prosecution re-activation
4. Increment `prosecution_depth_reactivations` in pipeline metrics by 1 for each event written.
