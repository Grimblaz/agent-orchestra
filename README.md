# Copilot Workflow Template

[![Version](https://img.shields.io/badge/version-v1.5.0-blue.svg)](../../releases)
[![Ready for Production](https://img.shields.io/badge/status-production%20ready-green.svg)](../../releases)

A multi-agent workflow system for GitHub Copilot that orchestrates AI-assisted software development across specialized agents.

## Quick Start — Two Steps

### Step 1: Clone or fork this template

```bash
git clone https://github.com/YOUR-ORG/YOUR-REPO.git
cd YOUR-REPO
```

Or click **"Use this template"** &rarr; **"Create a new repository"** on GitHub.

### Step 2: Run the setup wizard

Type `/setup` in GitHub Copilot Chat and answer the questions. Copilot will generate `.github/copilot-instructions.md` and `.github/architecture-rules.md` tailored to your project.

> **Prefer to do it manually?** Create `.github/copilot-instructions.md` and `.github/architecture-rules.md` yourself. See `examples/` for complete filled-in references showing the expected format.

That's it. You're ready to use agents.

---

## Using the Agents

### I want to

| Goal | Start here |
|------|-----------|
| Pick up a GitHub issue and design a solution | `@Issue-Designer` |
| Create an implementation plan for an issue | `@Issue-Planner` |
| Implement a planned feature end-to-end | `@Code-Conductor` |
| Review code and identify risks | `@Code-Critic` |
| Respond to a code review | `@Code-Review-Response` |
| Clean up completed work / archive tracking files | `@Janitor` |

### Core Workflow

```text
Issue → @Issue-Designer → @Issue-Planner → @Code-Conductor → PR
```

1. **@Issue-Designer** — picks up the issue, explores the design space, updates the issue body with a design
2. **@Issue-Planner** — creates a step-by-step implementation plan as an issue comment
3. **@Code-Conductor** — reads the plan, delegates to internal specialist agents, creates a merge-ready PR
