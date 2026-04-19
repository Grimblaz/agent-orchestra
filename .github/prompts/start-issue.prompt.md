---
agent: agent
description: "Start work on a GitHub issue — sets up the feature branch, initializes tracking, and delegates to Issue-Planner for a structured implementation plan."
---

# Start Issue Prompt

Use this prompt when beginning work on a new issue to ensure proper setup and workflow initialization.

---

## Prompt Template

```text
I'm starting work on issue #[ISSUE_NUMBER]. Please help me set up and begin the workflow.

**Issue Title**: [ISSUE_TITLE]
**Issue Description**: [BRIEF_SUMMARY]

Please complete the following setup steps:

1. **Read and Analyze Issue**
   - Review the full issue description
   - Identify all acceptance criteria
   - Note any dependencies or blockers
   - Ask clarifying questions if needed

2. **Check Dependencies**
   - Verify all required tools are installed
   - Check if any related issues need to be completed first
   - Identify any external dependencies
   - [CUSTOMIZE: Add project-specific dependency checks]

3. **Create Feature Branch**
   - Branch name: `feature/issue-[ISSUE_NUMBER]-[descriptive-name]`
   - Based on: `[main/develop/CUSTOMIZE_BASE_BRANCH]`
   - Command: `git checkout -b feature/issue-[ISSUE_NUMBER]-[descriptive-name]`

4. **Initialize Tracking**
   - Confirm `.copilot-tracking/` directory exists for research notes and archived tracking files (create if absent)
   - Issue-Planner (Step 6) will save the plan to session memory at `/memories/session/plan-issue-[ISSUE_NUMBER].md` and cache design context at `/memories/session/design-issue-[ISSUE_NUMBER].md` after research and approval

5. **Project-Specific Setup**
   [CUSTOMIZE: Add any project-specific setup steps, such as:]
   - Environment variable checks
   - Database migrations needed
   - API keys or credentials
   - Service dependencies to start

6. **Create Implementation Plan**
   - Delegate to @Issue-Planner to research and draft a structured plan.
   - Assess complexity: MINIMAL | MORE | A LOT
   - Break down into phases
   - Assign agents to phases

After setup is complete, please confirm:
- [ ] Issue understood and acceptance criteria clear
- [ ] No blocking dependencies
- [ ] Feature branch created
- [ ] Tracking initialized
- [ ] Implementation plan ready
- [ ] Ready to begin Phase 1 (Research)

If any issues are found during setup, please report them before proceeding.
```

---

## Usage Instructions

### For Solution-Designer

When picking up a new issue:

1. **Copy this prompt** and fill in the placeholders:
   - `[ISSUE_NUMBER]`: The GitHub issue number
   - `[ISSUE_TITLE]`: The issue title
   - `[BRIEF_SUMMARY]`: 1-2 sentence summary of what needs to be done
   - `[CUSTOMIZE_*]`: Replace with project-specific values

2. **Execute the checklist** systematically, using appropriate agents:
   - Analysis: Solution-Designer handles initial review
   - Dependencies: [CUSTOMIZE: Specify agent responsible for dependency checks] can check dependencies
   - Branch creation: Solution-Designer or Code-Conductor
   - Tracking: Solution-Designer sets up tracking
   - Planning: Issue-Planner creates implementation plan

3. **Document blockers**: If any dependency or setup issue is found, document it in the issue comments before proceeding.

4. **Confirm readiness**: Ensure all checklist items are complete before handing off to execution agents.

---

## Customization Guide

### Project-Specific Dependency Checks

Add checks relevant to your technology stack:

**Example for Node.js**:

```bash
- Node version >= [VERSION]
- NPM dependencies installed (`npm install`)
- Environment variables set (`.env` file)
```

**Example for Java/Spring Boot**:

```bash
- JDK version >= [VERSION]
- Maven/Gradle dependencies resolved
- Application properties configured
- Database connection verified
```

**Example for Python**:

```bash
- Python version >= [VERSION]
- Virtual environment activated
- Requirements installed (`pip install -r requirements.txt`)
- Environment variables set
```

### Project-Specific Setup Steps

Add steps that must be completed before starting work:

**Examples**:

- Start local database: `docker-compose up -d database`
- Run migrations: `npm run migrate` or `python manage.py migrate`
- Generate API clients: `npm run generate-client`
- Start dependent services: `docker-compose up -d redis rabbitmq`
- Clear caches: `npm run cache:clear`

### Branch Naming Conventions

Adjust the branch naming pattern to match your project:

**Examples**:

- `feature/issue-[ISSUE_NUMBER]-[description]` (default)
- `feat/PROJ-[ISSUE_NUMBER]-[description]` (with Jira-style prefixes)
- `feature/[ISSUE_NUMBER]/[description]` (with slash separators)
- `[github-handle]/issue-[ISSUE_NUMBER]-[description]` (with developer name)

---

## Workflow Integration

### Agent Handoff

After completing setup with this prompt:

1. **Solution-Designer** → **Issue-Planner**: Pass issue details for planning
2. **Issue-Planner** → **Code-Conductor**: Issue-Planner saves the implementation plan and design cache to session memory; Continue implementation uses session memory only as the same-session source of truth. At D9, if the user chooses Stop / Pause / resume later, Code-Conductor persists durable GitHub issue comments with the `<!-- plan-issue-[ISSUE_NUMBER] -->` and `<!-- design-issue-[ISSUE_NUMBER] -->` markers for handoff
3. **Code-Conductor** → **Specialized Agents**: Execute phases sequentially

### Plan Storage

Issue-Planner saves the plan to session memory at `/memories/session/plan-issue-[ISSUE_NUMBER].md` and caches design context at `/memories/session/design-issue-[ISSUE_NUMBER].md` using the `vscode/memory` tool. The plan includes YAML frontmatter (see Issue-Planner Section 6 in `agents/Issue-Planner.agent.md` for field definitions) and a `## Plan` heading with the full implementation steps. Continue implementation uses session memory only as the same-session source of truth. At D9, if the user explicitly chooses Stop / Pause / resume later, Code-Conductor persists durable GitHub issue comments with the `<!-- plan-issue-[ISSUE_NUMBER] -->` and `<!-- design-issue-[ISSUE_NUMBER] -->` markers for cross-session or cloud-agent handoff.

---

## Quick Start Checklist

For a rapid start without the full prompt, ensure these minimum requirements:

- [ ] Issue read and understood
- [ ] Feature branch created: `feature/issue-[ISSUE_NUMBER]-[name]`
- [ ] Implementation plan delegated to @Issue-Planner
- [ ] Plan saved by Issue-Planner to session memory: `/memories/session/plan-issue-[ISSUE_NUMBER].md`
- [ ] No blocking dependencies

Then proceed to Phase 1: Research & Planning.

---

## Tips for Success

1. **Don't rush setup**: Taking time to properly set up the workflow prevents issues later
2. **Ask questions early**: If the issue is unclear, ask for clarification before starting implementation
3. **Document assumptions**: If you make assumptions during setup, document them in the tracking file
4. **Check for related work**: Search for related issues or PRs that might provide context
5. **Verify tooling**: Ensure all required tools and dependencies are working before proceeding

---

**Last Updated**: December 31, 2025
**Template Version**: 1.2.0
