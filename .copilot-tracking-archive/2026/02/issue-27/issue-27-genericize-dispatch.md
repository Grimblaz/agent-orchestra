---
status: ready
issue_id: "27"
created: 2026-02-23
review_loop_budget: 2
visual_verification: false
---

## Plan: Genericize Dispatch Workflow

Replace the org-coupled `notify-agent-sync.yml` with a generic, variable-driven, dual-mode dispatch workflow. Remove all `Grimblaz-and-Friends`/`Organizations-of-Elos` references from active files. Archive the issue-17 design doc. Document the sync model in CUSTOMIZATION.md. This is a non-UI project — no visual verification checkpoints. Design doc: [Documents/Design/issue-27-genericize-dispatch.md](Documents/Design/issue-27-genericize-dispatch.md).

**Decisions**

- Issue-19 design doc (`Documents/Design/issue-19-migrate-skills.md`): leave as-is — historical context, not structural coupling
- Sync documentation location: `CUSTOMIZATION.md` section 7
- Clone URL `Grimblaz/workflow-template` in README: leave as-is — actual repo URL, not org-specific coupling
- Branch: reuse existing `feature/issue-27-genericize-dispatch`

**Steps**

### Step 1 — Rewrite dispatch workflow

Execution Mode: serial

**Requirement Contract**:

- AC: `notify-agent-sync.yml` uses `vars.DOWNSTREAM_REPOS` matrix (no hard-coded repos)
- AC: Fires `agent-sync` on push to `main` (paths: `.github/agents/**`), `agent-release` on release publish
- AC: No `Grimblaz/workflow-template` guard; uses `vars.DOWNSTREAM_REPOS != ''` guard instead
- AC: `source_repo` uses `${{ github.repository }}` runtime context
- Invariant: Workflow YAML must be valid
- Non-goal: Testing actual dispatch (requires secrets + downstream repos)

**Changes**: Replace entire contents of `.github/workflows/notify-agent-sync.yml` with the design doc's YAML spec:

- Add `release: types: [published]` trigger alongside existing `push` trigger
- Replace `if: github.repository == 'Grimblaz/workflow-template'` with `if: vars.DOWNSTREAM_REPOS != ''`
- Replace single `curl` to hard-coded `Grimblaz-and-Friends/.github-private` repo with `matrix.repo` from `fromJSON(vars.DOWNSTREAM_REPOS)`
- Use conditional `EVENT_TYPE` env var: `agent-sync` for pushes, `agent-release` for releases
- Rename job from `notify-sync` to `notify-downstream`
- Rename step from "Dispatch sync event to .github-private" to "Dispatch agent-sync event"
- Use `${{ github.repository }}` instead of hard-coded `Grimblaz/workflow-template` for `source_repo` payload

**TDD Cycle**:

- Red: Verify current workflow has hard-coded references (confirmed during research)
- Green: Apply the full rewrite per design spec YAML
- Refactor: Verify shell script best practices (`set -euo pipefail`, proper quoting)

**Validation**: Manual YAML syntax review; grep for `Grimblaz` in workflow file returns 0 matches

---

### Step 2 — Clean README.md

Execution Mode: serial

**Requirement Contract**:

- AC: No references to `Grimblaz-and-Friends` or `Organizations-of-Elos` in README
- AC: Version badge matches latest release (`v1.3.2`)
- AC: `.github-private` generic mention (L284 — describes GitHub feature concept) remains untouched
- Non-goal: Changing clone URL `Grimblaz/workflow-template` (actual repo URL)

**Changes** in `README.md`:

- L3: Update version badge from `v1.2.2` to `v1.3.2`
- L326-330: Remove entire "Related" section containing `Organizations-of-Elos` provenance links and external tracking issue

**TDD Cycle**:

- Red: Grep confirms `Organizations-of-Elos` and `Grimblaz-and-Friends` exist in README
- Green: Update badge, remove "Related" section
- Refactor: Ensure no orphaned headers, trailing whitespace, or broken markdown

**Validation**: `grep -n "Grimblaz-and-Friends\|Organizations-of-Elos" README.md` returns no results

---

### Step 3 — Archive issue-17 design doc

Execution Mode: serial

**Requirement Contract**:

- AC: `Documents/Design/issue-17-sync-org-agents.md` no longer exists at current path
- AC: File preserved in `.copilot-tracking-archive/`
- Invariant: File content unchanged (archival only, no editing)
- Non-goal: Cleaning org references within the archived file

**Changes**:

- Move `Documents/Design/issue-17-sync-org-agents.md` to `.copilot-tracking-archive/2026/02/issue-17/issue-17-sync-org-agents.md`
- Target directory `.copilot-tracking-archive/2026/02/issue-17/` already exists (has prior archival content)

**TDD Cycle**:

- Red: Confirm file exists at source path
- Green: Move the file
- Refactor: Verify `Documents/Design/` still contains `issue-19-migrate-skills.md` and `issue-27-genericize-dispatch.md` only

**Validation**: `Test-Path Documents/Design/issue-17-sync-org-agents.md` returns False; file exists in archive path

---

### Step 4 — Add sync documentation to CUSTOMIZATION.md

Execution Mode: serial

**Requirement Contract**:

- AC: Sync model documented for template adopters
- AC: Documents `DOWNSTREAM_REPOS` variable setup and `AGENT_SYNC_PAT` secret creation
- AC: Explains streaming (`agent-sync`) vs stable (`agent-release`) event types with decision table
- AC: Includes consumer-side workflow YAML snippet
- AC: Notes privacy — repo variables require write access, not publicly visible
- Non-goal: Duplicating the design doc — keep practical and adopter-focused

**Changes** in `CUSTOMIZATION.md`:

- Add new section "### 7. Downstream Sync" after existing "### 6. Set Up CI/CD" section (~L116)
- Subsections: Purpose, Setup (variable + secret), Event Types table, Consumer-Side Pattern (YAML snippet), Privacy Note

**TDD Cycle**:

- Red: Confirm no sync documentation exists in CUSTOMIZATION.md
- Green: Add the new section with all required content
- Refactor: Verify section numbering consistency; ensure markdown renders cleanly

**Validation**: Visual review of rendered markdown in preview

---

### Step 5 — Final audit for remaining org references

Execution Mode: serial

**Requirement Contract**:

- AC: No `Grimblaz-and-Friends` references in any active file on the branch
- AC: No `Organizations-of-Elos` references in active docs (archive + issue-19 design doc acceptable)
- AC: `.github-private` references are only the generic GitHub feature mentions (README L284, CUSTOMIZATION.md "Organization-Level Agents")
- Decision: `Documents/Design/issue-19-migrate-skills.md` left as-is per user decision

**Changes**: Run comprehensive grep across all files. Clean any unexpected references found.

**Validation**:

```bash
grep -rn "Grimblaz-and-Friends" --include="*.md" --include="*.yml" --include="*.yaml" .
grep -rn "Organizations-of-Elos" --include="*.md" --include="*.yml" .
```

Expected: Only matches in `.copilot-tracking-archive/` and `Documents/Design/issue-19-migrate-skills.md`

---

### Step 6 — Refactor pass

Execution Mode: serial

Broader refactoring while context is fresh:

- Review `Documents/Design/` directory — flag if any other stale or irrelevant docs exist
- Verify `CUSTOMIZATION.md` section numbering is consistent after step 4 insertion
- Confirm design doc `Documents/Design/issue-27-genericize-dispatch.md` is present on branch
- Check for any other quality improvements related to the changed files

---

### Step 7 — Code review (Code-Critic → Code-Review-Response)

Execution Mode: serial | Review loop budget: 2 rebuttal rounds

- Code-Critic reviews all changes against issue #27 acceptance criteria and design decisions
- Code-Review-Response adjudicates findings with evidence-based dispositions
- Dispute resolution: up to 2 rebuttal rounds before escalation
- Deferral handling: improvements >1 day marked `DEFERRED-SIGNIFICANT` with follow-up issues created automatically
- Convergence: all items reach terminal state (ACCEPT / REJECT / DEFERRED-SIGNIFICANT)

### Step 8 — Process retrospective checkpoint

Brief post-issue retrospective:

- Any slowdowns or late-failing checks encountered?
- One workflow guardrail improvement to capture

**Verification (all steps)**

- `grep -rn "Grimblaz-and-Friends" . --include="*.md" --include="*.yml"` — only archive hits
- `grep -rn "Organizations-of-Elos" . --include="*.md" --include="*.yml"` — only archive + issue-19 design doc
- Workflow YAML valid (manual review or linter)
- README badge shows `v1.3.2`
- CUSTOMIZATION.md has "Downstream Sync" section with variable setup, event types, consumer pattern
- `Documents/Design/issue-17-sync-org-agents.md` archived to `.copilot-tracking-archive/`
- All 7 acceptance criteria from issue #27 satisfied
