# Copilot Workflow Template

[![Version](https://img.shields.io/badge/version-v1.2.2-blue.svg)](../../releases)
[![Ready for Production](https://img.shields.io/badge/status-production%20ready-green.svg)](../../releases)

A multi-agent workflow system for GitHub Copilot, designed to orchestrate AI-assisted software development through specialized agents.

> **Ready to use!** Clone this repository and immediately start working with 15+ specialized AI agents. Complete with TDD workflow skills, implementation templates, and a Spring Boot example project.

## Overview

This template provides a proven framework for working with AI coding agents, featuring:

| Agent | Role |
|-------|------|
| **Issue Designer** | Picks up issues, prepares environment, creates design docs |
| **Research Agent** | Performs deep research on proposed changes |
| **Code Conductor** | Orchestrates implementation via sub-agents |
| **Code-Smith** | Writes production code |
| **Test-Writer** | Creates comprehensive tests |
| **Refactor-Specialist** | Improves code quality and structure |
| *...and more* | Additional specialized agents for various tasks |

## Quick Start

Get up and running in under 5 minutes:

> **Requirements**: VS Code 1.107+ recommended for automatic skill discovery from `.claude/skills/`. See [CONTRIBUTING.md](CONTRIBUTING.md#setup) for setup details.

### 1. Get the Template

**Option A: Use as GitHub Template**

1. Click **"Use this template"** → **"Create a new repository"**
2. Clone your new repository

**Option B: Clone Directly**

```bash
git clone https://github.com/Grimblaz/workflow-template.git
cd workflow-template
```


### 2. Essential Customization (First-Time Setup)

Before using agents, customize these key files:

| Priority | File | Purpose | Required? |
|----------|------|---------|-----------|
| **HIGH** | `.github/copilot-instructions.md` | Your project context & tech stack | ✅ Yes |
| **HIGH** | `.github/architecture-rules.md` | Your architecture patterns | ✅ Yes |
| Medium | `.claude/skills/` | Add domain-specific skills | Recommended |
| Low | `.github/agents/` | Tweak agent behaviors | Optional |

> 📖 **See [CUSTOMIZATION.md](CUSTOMIZATION.md)** for detailed step-by-step guidance.

**Quick Setup Checklist:**

- [ ] Create `.github/copilot-instructions.md` (use `examples/spring-boot-microservice/copilot-instructions.md` as reference)
- [ ] Create `.github/architecture-rules.md` (use `examples/spring-boot-microservice/architecture-rules.md` as reference)
- [ ] Review `.github/agents/` - familiarize yourself with available agents
- [ ] Optionally add project-specific skills to `.claude/skills/`

### 3. Your First Agent Conversation

Once setup is complete, start using agents immediately:

**Example: Pick up an issue**

```markdown
@issue-designer

Please pick up issue #42 and prepare the environment for implementation.
```


**Example: Start implementation**

```markdown
@code-conductor

I've reviewed the design in Documents/Design/issue-42-design.md.
Please orchestrate implementation of this feature.
```


**Example: Write tests first**

```markdown
@test-writer

Using the TDD workflow skill, please write tests for the UserService.createUser method
following the specification in the design doc.
```


> 💡 **Tip**: The `@agent-name` syntax is a convention. GitHub Copilot Chat will use the agent definitions from `.github/agents/` when you reference them in your prompts.

### 4. Start Building

You're ready! The agents will:

- 🎯 Follow your architecture rules
- 📝 Use your project conventions from `copilot-instructions.md`
- 🛠️ Apply domain skills when relevant
- ✅ Generate implementation plans and track progress

## What's Included

This template is **production-ready** and includes everything you need to start working with AI agents:

### 🤖 Agents (15 Specialized)

Complete set of agent definitions in `.github/agents/`:

- **Issue-Designer** - Design exploration and issue management for new features
- **Research-Agent** - Comprehensive technical analysis and pattern discovery
- **Code-Conductor** - Plan-driven workflow orchestration across implementation steps
- **Code-Smith** - Focused code implementation using TDD or plan-driven execution
- **Test-Writer** - Behavior-focused test writing and validation
- **Refactor-Specialist** - Proactive refactoring and code quality improvement
- **Plan-Architect** - Implementation plan architecture and specialist constraints
- **Doc-Keeper** - Documentation finalization and accuracy verification
- **Code-Critic** - Adversarial code review and risk discovery
- **Code-Review-Response** - Adjudicates review findings and delegates execution
- **Janitor** - Cleanup and technical debt remediation
- **Issue-Planner** - Multi-step planning and implementation outline creation
- **Process-Review** - Workflow compliance and process improvement analysis
- **Specification** - Specification document creation and updates
- **UI-Iterator** - Screenshot-based UI polish and visual iteration

### 🎯 Skills Framework (8 Skills)

Reusable skill definitions in `.claude/skills/`:

| Skill | Purpose |
|-------|---------|
| **tdd-workflow** | TDD process knowledge and workflow guidance |
| **brainstorming** | Structured Socratic questioning for exploring ideas |
| **frontend-design** | Distinctive UI design guidance |
| **ui-testing** | Resilient React component testing |
| **skill-creator** | Guide for creating new skills |
| **systematic-debugging** | 4-phase debugging process |
| **verification-before-completion** | Evidence-based verification checklist |
| **software-architecture** | Clean Architecture and SOLID principles |

> **VS Code 1.107+**: Skills are auto-discovered from `.claude/skills/` via the `description` frontmatter field.

### 📋 Templates & Instructions

Ready-to-use templates in `.github/`:

- **Implementation Plan Template** - Standard structure for feature implementation
- **Start Issue Prompt** - Quick-start prompts for issue-designer
- **Tracking Format Instructions** - Standard output format for agent responses
- **Post-PR Review Instructions** - Guidelines for after PR review

### 🛠️ Scripts & Workflows

Foundation for automation in `.github/`:

- **Validation Scripts** - Template for test/lint validation
- **CI Workflows** - Template for continuous integration

### 📚 Example Project

Complete Spring Boot microservice example in `examples/`:

- `copilot-instructions.md` - Project context example
- `architecture-rules.md` - Architecture patterns example
- `TECH-DEBT.md` - Technical debt tracking template
- Demonstrates how to adapt the template for your stack

## Repository Structure

```text
.github/
├── agents/              # Agent definitions (15+ specialized agents)
├── instructions/        # Tracking format, PR review guidelines
├── templates/           # Implementation plan templates
├── prompts/             # Execution prompts for agents
├── scripts/             # Validation scripts
└── workflows/           # CI/CD workflow templates

.claude/skills/          # Reusable skill definitions (8 skills)
├── README.md            # Skills framework documentation
├── tdd-workflow/        # Test-Driven Development
├── brainstorming/       # Socratic questioning
├── frontend-design/     # UI design guidance
├── ui-testing/          # React component testing
├── skill-creator/       # Creating new skills
├── systematic-debugging/ # 4-phase debugging
├── verification-before-completion/  # Completion checklist
└── software-architecture/  # Clean Architecture & SOLID

examples/
└── spring-boot-microservice/  # Complete example project

Documents/
├── Design/              # Design documents (created by agents)
├── Decisions/           # Architecture Decision Records (ADRs)
└── Development/         # Project documentation templates
```

## Key Concepts

### Agents

Agents are specialized AI personas defined in `.github/agents/`. Each agent has:

- A specific role and expertise
- Defined responsibilities
- Interaction patterns with other agents

### Skills

Skills are domain-specific knowledge packages in `.claude/skills/`. They provide:

- Contextual information for agents
- Best practices for specific workflows
- Examples and patterns to follow

### Instructions

Instructions in `.github/instructions/` guide agent behavior:

- Output formats (tracking, documentation)
- Review processes
- Quality standards

## Customization

**📖 [Read the Complete Customization Guide](CUSTOMIZATION.md)** for step-by-step instructions.

### Quick Reference: Files to Customize

| File | What to Customize | When |
|------|-------------------|------|
| `.github/copilot-instructions.md` | Project overview, tech stack, conventions | **Before first use** |
| `.github/architecture-rules.md` | Layer structure, package organization, dependency rules | **Before first use** |
| `.claude/skills/your-domain/` | Domain-specific patterns, examples, best practices | As needed |
| `.github/agents/*.md` | Agent behaviors, responsibilities, interaction patterns | Optional refinement |
| `.github/templates/*.md` | Implementation plan structure, issue templates | Optional refinement |
| `.github/workflows/*.yml` | CI/CD pipelines, automation | When setting up CI |

### Technology-Specific Adaptation

All examples in this template use **Java/Spring Boot** conventions. When adapting for other stacks:

- **Node.js/Express**: Replace test commands (`./gradlew test` → `npm test`), adjust layer patterns
- **Python/Django**: Update architecture rules for Django patterns (views, models, serializers)
- **Go**: Adapt package structure conventions, replace build commands
- **.NET/C#**: Update for .NET patterns (Controllers, Services, Repositories)

The **conceptual structure** (agents, skills, workflows) remains the same - only the concrete examples change.

> 💡 **Tip**: Use the Spring Boot example in `examples/spring-boot-microservice/` as a reference for how to structure your own technology-specific customization.

## Design Philosophy

### Standalone Template with Manual Sync

This template follows a **copy-and-adapt** model:

- No automatic updates to consumer repositories
- Versioned releases (tags) for upgrade reference points
- Each project maintains ownership of customizations
- Improvements flow back via PRs to this template

### Why This Approach?

1. **Independence** - Your project isn't blocked by template changes
2. **Flexibility** - Adapt freely to your specific needs
3. **Stability** - Upgrade on your schedule
4. **Control** - You decide what changes to incorporate

## Organization-Level Setup

You can define shared Agent definitions at the organization level in either:

- An organization `.github-private` repository
- An organization `.github` repository

For organization repositories, place definitions in an `agents/` folder at repository root.

Organization-level Agents apply across repositories in that organization. Repository-level Agents in this template (`.github/agents/`) can override organization defaults when project-specific behavior is needed.

## Example Projects

This template includes example configurations for:

- **Spring Boot Microservice** - Layered architecture (Controller → Service → Repository)

> **Note**: All concrete examples throughout this template (test commands, quality gates, code patterns) use **Java/Spring Boot** conventions. When adapting for other stacks (Node.js, Python, etc.), replace these with your framework's equivalents while keeping the same conceptual structure.

The examples demonstrate how agents and skills work in practice, serving as a reference for adaptation to your specific technology stack.

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Ways to contribute:

- Report issues with agent definitions
- Share improvements to prompts
- Add new skill definitions
- Improve documentation

## Versioning

This project uses semantic versioning:

- **Major** - Breaking changes to agent interfaces
- **Minor** - New agents, skills, or features
- **Patch** - Bug fixes and documentation

Check [Releases](../../releases) for version history.

## License

This project is available for use under the terms specified in the LICENSE file.

## Related

- Originally extracted from [Organizations-of-Elos](https://github.com/Grimblaz-and-Friends/Organizations-of-Elos)
- Tracking issue: [#77](https://github.com/Grimblaz-and-Friends/Organizations-of-Elos/issues/77)
