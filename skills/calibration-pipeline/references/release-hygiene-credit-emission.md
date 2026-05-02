# Release-Hygiene v4 Credit Emission

Extracted from `agents/Code-Conductor.agent.md` per the D5 size-ceiling extraction pattern
(issue #441 Step 7b, issue #403 Step 8 size contract).

## Frame Credits (v4) — release-hygiene Row

After emitting the inherited v3 pipeline-metrics block, bump `metrics_version` to `4` and append a
`credits[]` array and `frame_version: 1` using the canonical v4 schema from
`frame/pipeline-metrics-v4-schema.md`. Credit rows are emitted at PR creation — not before.

### Reading the state file

Before creating the PR, determine the state-file slug using the same keying logic as
`Get-PRHKeyingInfo` in the PostToolUse hook (session-id preferred, then branch-slug).
Read `.claude/.state/release-hygiene-{slug}.json`.

If the state file exists and has a `symmetric_bump_credit` field:

1. Take `symmetric_bump_credit.port`, `adapter`, `status`, and `evidence` directly.
2. Set `run_index` to `1` (increment when a prior release-hygiene credit row already exists in the
   PR body for the same `(port, adapter)` pair).
3. Populate `symmetric-bump-verification.status` from `symmetric_bump_credit.status`.
4. Populate `symmetric-bump-verification.files-checked` with the canonical 5-file list:
   `["plugin.json", ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json",
   ".github/plugin/marketplace.json", "README.md"]`.
5. If `status == passed`: populate `version-bump.from` and `version-bump.to` by reading the
   current version from `plugin.json` and the baseline from the default branch
   (`git show origin/main:plugin.json`).
6. Emit the row in the `credits[]` array.

If the state file does not exist or has no `symmetric_bump_credit` field, skip the release-hygiene
credit row. Do not emit a placeholder row.

### Example: status=passed

```yaml
- port: release-hygiene
  adapter: symmetric-bump
  status: passed
  run_index: 1
  evidence: "all manifests at 2.8.0"
  version-bump:
    from: "2.7.0"
    to: "2.8.0"
  symmetric-bump-verification:
    status: passed
    files-checked: ["plugin.json", ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", ".github/plugin/marketplace.json", "README.md"]
```

### Example: status=not-applicable

```yaml
- port: release-hygiene
  adapter: symmetric-bump
  status: not-applicable
  run_index: 1
  evidence: "not-applicable (auto: no manifest change)"
  symmetric-bump-verification:
    status: not-applicable
    files-checked: []
```

## CE Gate S2 — Synthetic-PR Test Protocol

For CE Gate scenario S2 (release-hygiene credit verification), use this isolated test protocol:

1. Create branch `test/issue-441-release-hygiene-ce` from `main`.
2. Run `bump-version.ps1 -Version 99.99.1` to set all manifests to `99.99.1`.
   (`99.99.x` is a reserved test namespace — this version is never shipped.)
3. Commit on the branch: `git commit -m "test: contrived bump 99.99.1 for CE Gate S2"`.
4. Create a **draft** PR: `gh pr create --draft --title "test: CE Gate S2 release-hygiene" --body "..."`.
5. Verify the credit row in the PR body: `gh pr view {N} --json body | yq '.body'` — expect a
   `release-hygiene` credit with `status: passed`.
6. Close the PR without merging: `gh pr close {N}`.
7. Restore manifests via `git checkout main` (no merge needed — branch is discarded).

This protocol is isolated from production `.claude-plugin/plugin.json` because the branch is never
merged and `99.99.x` versions are reserved for test use.
