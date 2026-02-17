# Spring Boot Microservice Example

This directory contains example configuration files for a Spring Boot microservice project using the multi-agent workflow template.

## Contents

| File | Purpose |
|------|---------|
| [copilot-instructions.md](copilot-instructions.md) | Project context for Copilot agents |
| [architecture-rules.md](architecture-rules.md) | Architectural constraints and patterns |
| [TECH-DEBT.md](TECH-DEBT.md) | Technical debt tracking template |

## How to Use These Examples

### Option 1: Copy to Your Project

Copy the files you need to your project's `.github/` directory:

```bash
# From your project root
cp /path/to/workflow-template/examples/spring-boot-microservice/copilot-instructions.md .github/
cp /path/to/workflow-template/examples/spring-boot-microservice/architecture-rules.md .github/
cp /path/to/workflow-template/examples/spring-boot-microservice/TECH-DEBT.md ./
```

### Option 2: Use as Reference

Review these files and adapt the patterns to your specific project needs. Key areas to customize:

- **Technology versions** (Java, Spring Boot, etc.)
- **Package structure** (match your actual packages)
- **Layer rules** (adjust for your architecture)
- **Testing requirements** (match your coverage goals)

## Customization Guide

### copilot-instructions.md

This file provides context that all Copilot agents will reference. Customize:

1. **Project Overview**: What does your service do?
2. **Technology Stack**: Your actual versions and tools
3. **Architecture**: Your specific patterns
4. **Conventions**: Your team's coding standards
5. **Build Commands**: Your actual build/run commands

### architecture-rules.md

Defines what agents should and shouldn't do architecturally. Customize:

1. **Layer Definitions**: Match your actual layers
2. **Dependency Rules**: What can depend on what
3. **API Conventions**: Your REST patterns
4. **Testing Requirements**: Your coverage needs
5. **Security Rules**: Your auth/authz approach

### TECH-DEBT.md

Tracks known shortcuts and issues. Customize:

1. **Priority Definitions**: Match your team's severity levels
2. **Categories**: Add/remove as needed
3. **Template**: Adjust entry format for your workflow
4. **Metrics**: Track what matters to your team

## File Placement

When using these in your project:

```text
your-project/
├── .github/
│   ├── copilot-instructions.md    # ← From this example
│   ├── architecture-rules.md      # ← From this example
│   ├── agents/                    # ← From workflow-template
│   └── ...
├── TECH-DEBT.md                   # ← From this example (project root)
├── src/
│   └── ...
└── ...
```

## Why These Files Matter

### For AI Agents

- **copilot-instructions.md**: Provides project context, preventing generic responses
- **architecture-rules.md**: Ensures generated code follows your patterns
- **TECH-DEBT.md**: Helps agents avoid problematic areas or fix debt opportunistically

### For Your Team

- **copilot-instructions.md**: Documents tribal knowledge
- **architecture-rules.md**: Codifies architectural decisions
- **TECH-DEBT.md**: Makes technical debt visible and trackable

## See Also

- [Main Customization Guide](../../CUSTOMIZATION.md)
- [Agent Definitions](../../.github/agents/)
- [TDD Workflow Skill](../../.github/skills/test-driven-development/)
