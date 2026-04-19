# Node.js / TypeScript Example

This directory contains example configuration files for a Node.js / TypeScript project using Express and Agent Orchestra.

## Contents

| File | Purpose |
|------|---------|
| [copilot-instructions.md](copilot-instructions.md) | Project context for Copilot agents |
| [architecture-rules.md](architecture-rules.md) | Architectural constraints and patterns |

## How to Use These Examples

### Option 1: Generate Automatically

Run the setup prompt in GitHub Copilot Chat to generate these files tailored to your project:

```text
/setup
```

Or open `.github/prompts/setup.prompt.md` in VS Code and run it via Copilot Chat to produce customized versions of these files automatically.

### Option 2: Copy and Adapt

Copy the files you need to your project's `.github/` directory:

```bash
# From your project root
cp /path/to/agent-orchestra/examples/nodejs-typescript/copilot-instructions.md .github/
cp /path/to/agent-orchestra/examples/nodejs-typescript/architecture-rules.md .github/
```

Then edit them to match your actual project name, versions, and conventions.

### Option 3: Use as Reference

Review these files and adapt the patterns to your specific project needs. Key areas to customize:

- **Technology versions** (Node.js, TypeScript, Express, etc.)
- **Directory structure** (match your actual layout)
- **Layer rules** (adjust for your architecture)
- **Testing requirements** (match your coverage goals)

## Customization Guide

### copilot-instructions.md

This file provides context that all Copilot agents will reference. Customize:

1. **Project Overview**: What does your service do?
2. **Technology Stack**: Your actual versions and tools
3. **Architecture Diagram**: Your specific layer structure
4. **Conventions**: Your team's TypeScript and coding standards
5. **Build Commands**: Your actual build/run/test commands

### architecture-rules.md

Defines what agents should and shouldn't do architecturally. Customize:

1. **Layer Definitions**: Match your actual layers
2. **Dependency Rules**: What can depend on what
3. **API Conventions**: Your REST patterns and response shapes
4. **Testing Requirements**: Your coverage needs and tooling

## File Placement

When using these in your project:

```text
your-project/
├── .github/
│   ├── copilot-instructions.md    # ← From this example
│   ├── architecture-rules.md      # ← From this example
│   ├── agents/                    # ← From agent-orchestra
│   └── ...
├── src/
│   └── ...
└── ...
```

## Why These Files Matter

### For AI Agents

- **copilot-instructions.md**: Ensures agents know your stack, patterns, and conventions
- **architecture-rules.md**: Prevents agents from bypassing layers or using forbidden patterns

### For Your Team

- **copilot-instructions.md**: Documents tribal knowledge and tech choices
- **architecture-rules.md**: Codifies architectural decisions enforceably

## See Also

- [Main Customization Guide](../../CUSTOMIZATION.md)
- [Agent Definitions](../../agents/)
- [Spring Boot Microservice Example](../spring-boot-microservice/)
- [Python Example](../python/)
