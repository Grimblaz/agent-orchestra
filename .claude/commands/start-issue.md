# Start Issue

Begin work on a GitHub issue with proper setup and planning.

## Usage

`/project:start-issue {issue-number}`

## Steps

1. **Read and analyze the issue**
   - Run `gh issue view $ARGUMENTS` to read the full issue
   - Identify acceptance criteria, dependencies, and blockers
   - Ask clarifying questions if requirements are ambiguous

2. **Check dependencies**
   - Verify required tools are installed
   - Check if related issues need to be completed first
   - Identify external dependencies

3. **Create feature branch**
   - Ensure you are on `main` and up to date: `git checkout main && git pull` (replace `main` with `master`, `develop`, or `trunk` if that is the project's default branch)
   - Create branch: `git checkout -b feature/issue-$ARGUMENTS-{descriptive-slug}` (`$ARGUMENTS` is pre-interpolated by Claude Code with the issue number before you read this file; `{descriptive-slug}` is an instruction for you to replace with a meaningful slug from the issue title)

4. **Research the codebase**
   - Search for relevant files, patterns, and existing implementations
   - Check `Documents/Design/` and `Documents/Decisions/` for prior design work
   - Read `.github/instructions/tracking-format.instructions.md` for tracking conventions
   - Identify the customer-facing surface for CE Gate (Web UI, REST/GraphQL, CLI, SDK, Batch, or none)

5. **Draft implementation plan**
   - Follow the planning guide in `.github/agents/Issue-Planner.agent.md`
   - Include: numbered steps, execution mode per step (serial/parallel), requirement contract per step, validation commands, CE Gate step (if applicable)
   - No code blocks in the plan — describe changes, link to files and symbols
   - The plan stress-test (Code-Critic design review) is covered in Phase 4 of `.github/agents/Issue-Planner.agent.md` — follow that guide for how to invoke it, incorporate or dismiss findings, and append the Stress-Test summary block.
   - Present the plan (with stress-test summary) for user approval before proceeding

6. **Save the plan**
   - **Preferred**: Post as a GitHub issue comment with `<!-- plan-issue-$ARGUMENTS -->` marker — durable, does not pollute the repo
   - **Fallback**: Save as `.copilot-tracking/plan-issue-$ARGUMENTS.md` (this directory is gitignored — do not save plan files at repo root or they will be committed)
   - The plan is the single source of truth for implementation

## After Planning

Once the plan is approved, use `/project:implement` to begin execution.
