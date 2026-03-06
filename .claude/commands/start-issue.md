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
   - Ensure you are on `main` and up to date: `git checkout main && git pull`
   - Create branch: `git checkout -b feature/issue-$ARGUMENTS-{descriptive-slug}`

4. **Research the codebase**
   - Search for relevant files, patterns, and existing implementations
   - Check `Documents/Design/` and `Documents/Decisions/` for prior design work
   - Read `.github/instructions/tracking-format.instructions.md` for tracking conventions
   - Identify the customer-facing surface for CE Gate (Web UI, REST/GraphQL, CLI, SDK, Batch, or none)

5. **Draft implementation plan**
   - Follow the planning guide in `.github/agents/Issue-Planner.agent.md`
   - Include: numbered steps, execution mode per step (serial/parallel), requirement contract per step, validation commands, CE Gate step (if applicable)
   - No code blocks in the plan — describe changes, link to files and symbols
   - Present the plan for user approval before proceeding

6. **Save the plan**
   - Save as a file on the branch (e.g., `plan-issue-$ARGUMENTS.md`) or post as a GitHub issue comment with `<!-- plan-issue-$ARGUMENTS -->` marker
   - The plan is the single source of truth for implementation

## After Planning

Once the plan is approved, use `/project:implement` to begin execution.
