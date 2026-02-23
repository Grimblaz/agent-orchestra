<!-- markdownlint-disable-file -->

# Research Notes: Genericize Dispatch Workflow (Issue #27)

## Research Executed

### File Analysis

- `.github/workflows/notify-agent-sync.yml` (42 lines)
  - Full workflow read. 3 hard-coded org references, 1 hard-coded repo reference, 1 hard-coded dispatch target. Entire file is org-specific.
- `README.md` (330 lines)
  - Full read. 4 org-specific references found, including clone URL and provenance section.
- `CUSTOMIZATION.md` (172 lines)
  - Full read. No org-specific references. No existing sync/dispatch documentation. Natural insertion point exists in "Step 6: Set Up CI/CD" section.
- `CONTRIBUTING.md` (121 lines)
  - Full read. No org-specific references. Standard contribution guidelines.
- `Documents/Design/issue-17-sync-org-agents.md` (115 lines)
  - Full read. Contains 1 `Grimblaz-and-Friends/.github-private` reference in the Summary. This is a historical design doc.
- `Documents/Design/issue-19-migrate-skills.md` (115 lines)
  - Contains 2 `Organizations-of-Elos` references (lines 9, 14). Historical design doc.
- `LICENSE` (22 lines)
  - Contains `Copyright (c) 2026 Grimblaz` on line 3. This is the copyright holder — intentionally org-specific and should NOT be genericized.

### Code Search Results

- `Grimblaz-and-Friends` (exact) — 8 matches across 3 source files + 1 archive file
- `.github-private` (exact) — 10 matches across 3 source files + 1 archive file
- `Organizations-of-Elos` — 5 matches across 2 source files
- `Grimblaz` (broad) — 12 matches across 4 source files + git internals
- `Grimblaz/workflow-template` — 3 matches in source files (workflow, README, git config)
- Downstream sync / dispatch documentation — 0 matches in README.md or CUSTOMIZATION.md

### External Research

- No external research needed — this is an internal refactoring task based on existing codebase analysis.

### Project Conventions

- Standards referenced: `.github/instructions/tracking-format.instructions.md`, `.github/instructions/post-pr-review.instructions.md`
- No `.github/copilot-instructions.md` exists on main yet (issue #20 plans to create it)
- No `.github/architecture-rules.md` exists on main yet (issue #20 plans to create it)
- `.copilot-tracking/` directory exists with `plans/` and `research/` subdirectories
- `.copilot-tracking-archive/` directory exists with `2026/02/issue-17/` containing archived research

## Key Discoveries

### 1. Complete Org-Reference Inventory (Source Files Only)

#### `.github/workflows/notify-agent-sync.yml`

| Line | Reference | Type |
|------|-----------|------|
| L15 | `github.repository == 'Grimblaz/workflow-template'` | Hard-coded repo guard |
| L18 | `Dispatch sync event to .github-private` | Hard-coded step name |
| L34 | `https://api.github.com/repos/Grimblaz-and-Friends/.github-private/dispatches` | Hard-coded dispatch target URL |
| L37 | `"event_type": "agent-sync"` | Event type (generic, fine to keep) |
| L39 | `"source_repo": "Grimblaz/workflow-template"` | Hard-coded source repo in payload |

#### `README.md`

| Line | Reference | Type |
|------|-----------|------|
| L40 | `git clone https://github.com/Grimblaz/workflow-template.git` | Clone URL in Quick Start |
| L284 | `An organization .github-private repository` | Generic mention of .github-private concept (not org-specific — describes GitHub's feature) |
| L328 | `Originally extracted from Organizations-of-Elos (https://github.com/Grimblaz-and-Friends/Organizations-of-Elos)` | Provenance link |
| L329 | `Tracking issue: #77 (https://github.com/Grimblaz-and-Friends/Organizations-of-Elos/issues/77)` | Provenance link |

#### `LICENSE`

| Line | Reference | Type |
|------|-----------|------|
| L3 | `Copyright (c) 2026 Grimblaz` | Copyright holder — **DO NOT CHANGE** |

#### `Documents/Design/issue-17-sync-org-agents.md`

| Line | Reference | Type |
|------|-----------|------|
| L9 | `Grimblaz-and-Friends/.github-private` | Historical design context |

#### `Documents/Design/issue-19-migrate-skills.md`

| Line | Reference | Type |
|------|-----------|------|
| L9 | `Organizations-of-Elos` | Historical design context |
| L14 | `Organizations-of-Elos` | Historical design context |

#### `.copilot-tracking-archive/2026/02/issue-17/20260216-org-vs-template-agent-comparison.md`

| Lines | References | Type |
|-------|-----------|------|
| L5, L80, L84, L92, L189, L208, L262 | Multiple `Grimblaz-and-Friends` and `.github-private` references | Archived research — should remain as-is |

### 2. Workflow YAML Structure Analysis

The workflow (`notify-agent-sync.yml`) is 42 lines with this structure:

```
name: Notify Agent Sync
on: push (main, paths: .github/agents/**)
permissions: contents: none
jobs:
  notify-sync:
    if: repo guard (HARD-CODED)
    runs-on: ubuntu-latest
    steps:
      - name: step name (HARD-CODED reference)
        env: AGENT_SYNC_PAT secret, SOURCE_SHA
        shell: bash
        run: |
          - PAT validation
          - curl POST to dispatch endpoint (HARD-CODED URL)
          - JSON payload with source_repo (HARD-CODED) and sha
```

**Key structural observations:**
- The `if:` guard on line 15 ensures the workflow only runs in the original repo — forks/template consumers skip it silently
- The dispatch URL, source_repo payload, and step name all have org-specific values
- The `paths:` trigger is `.github/agents/**` — this is generic and correct
- The secret name `AGENT_SYNC_PAT` is generic (not org-specific)
- The event type `agent-sync` is generic

### 3. `issue-27-genericize-dispatch.md` Design Doc Status

- **Does NOT exist on main.** `file_search` for `**/issue-27*` returned 0 results.
- A `feature/issue-27-genericize-dispatch` branch exists (confirmed via `.git/FETCH_HEAD`).
- The design doc likely exists only on that feature branch.

### 4. CUSTOMIZATION.md Sync Documentation Gap

- No existing documentation about downstream sync, dispatch workflows, or agent sync anywhere in README.md or CUSTOMIZATION.md.
- README.md § "Organization-Level Setup" (lines 280-288) describes org-level agents in `.github-private` / `.github` repos but does NOT mention the dispatch/sync workflow.
- CUSTOMIZATION.md § "Step 6: Set Up CI/CD" (line 123) is the natural place to document sync setup. Currently contains only: "Adapt workflows in `.github/workflows/`: Build and test pipeline, Code quality checks, Deployment automation."

### 5. Design Docs Status

| File | Status | Org References | Action Needed |
|------|--------|----------------|---------------|
| `issue-17-sync-org-agents.md` | Finalized | Yes (L9) | Archive to `Documents/Design/archived/` |
| `issue-19-migrate-skills.md` | Design Complete | Yes (L9, L14) | Archive to `Documents/Design/archived/` |
| `Documents/Decisions/` | Empty (.gitkeep only) | N/A | No action |

### 6. Directory Structure Confirmation

- `.copilot-tracking/` exists with: `.gitkeep`, `plans/`, `research/`
- `.copilot-tracking/plans/` contains: `19-migrate-skills.md`, `20-plug-and-play-usability.md`
- `.copilot-tracking/research/` contains: `20260216-migrate-skills-research.md`, `20260216-onboarding-experience-research.md`
- `.copilot-tracking-archive/` exists with: `2026/02/issue-17/` (contains archived issue-17 research)
- No `Documents/Design/archived/` directory exists yet

### 7. README.md Line 284 — Not Actually Org-Specific

Line 284 (`An organization .github-private repository`) is a **generic description of GitHub's organization-level repository feature**, not a reference to the specific `Grimblaz-and-Friends/.github-private` repo. This line does NOT need to change. It's explaining *where* users can put shared agents.

### 8. README.md Clone URL (Line 40) — Needs Decision

The clone URL `https://github.com/Grimblaz/workflow-template.git` in the Quick Start section is the actual repo URL. Two options:
- **Option A**: Replace with a generic `https://github.com/YOUR-ORG/your-repo.git` placeholder
- **Option B**: Keep as-is since it's the actual clone URL for this template, and "Use as template" is the primary flow

## Recommended Approach

**Genericize the dispatch workflow using repository variables** instead of hard-coded values, while cleaning up org-specific references in documentation.

### Workflow Changes

Replace hard-coded org references in `notify-agent-sync.yml` with GitHub Actions repository variables (`vars.*`):

1. **Line 15**: Change repo guard from `'Grimblaz/workflow-template'` → `vars.SYNC_SOURCE_REPO` check, or remove guard entirely (the workflow is harmless without the secret configured)
2. **Line 34**: Replace hard-coded URL with `vars.SYNC_TARGET_REPO` → `https://api.github.com/repos/${{ vars.SYNC_TARGET_REPO }}/dispatches`
3. **Line 39**: Replace hard-coded source_repo with `${{ github.repository }}` (dynamic, always correct)
4. **Line 18**: Genericize step name to `Dispatch sync event to downstream repo`

### Documentation Changes

1. **CUSTOMIZATION.md**: Add a "Downstream Agent Sync" section under CI/CD explaining how to configure the variables
2. **README.md L40**: Replace clone URL with generic placeholder or `YOUR-USERNAME` pattern
3. **README.md L328-329**: Move provenance to a less prominent location or remove (these are org-specific attribution links)
4. **Design docs**: Archive `issue-17` and `issue-19` design docs (they contain org refs and are historical)

### What NOT to Change

- `LICENSE` line 3 — copyright holder is intentionally specific
- `.copilot-tracking-archive/` files — historical records stay as-is
- README.md line 284 — generic description of GitHub's `.github-private` feature, not org-specific

## Implementation Guidance

- **Objectives**: Remove all org-specific references from source files (excluding LICENSE copyright), making the template truly generic and forkable
- **Key Tasks**: (1) Genericize workflow YAML with vars, (2) Update README provenance/clone URL, (3) Add sync documentation to CUSTOMIZATION.md, (4) Archive historical design docs
- **Dependencies**: Issue #27 design doc on feature branch should be reviewed/merged to main before or alongside this work. Issues #19 and #20 plans exist in `.copilot-tracking/plans/` — no conflicts expected.
- **Success Criteria**: `grep -r "Grimblaz-and-Friends\|Organizations-of-Elos" --include="*.md" --include="*.yml"` returns only LICENSE and archived files. Workflow uses `vars.*` for all configurable values. CUSTOMIZATION.md documents sync setup.
