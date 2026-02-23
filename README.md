# Copilot Workflow Template

[![Version](https://img.shields.io/badge/version-v1.4.0-blue.svg)](../../releases)
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

> **Requirements**: VS Code 1.108+ recommended for automatic skill discovery from `.github/skills/` with `chat.useAgentSkills` enabled. See [CONTRIBUTING.md](CONTRIBUTING.md#setup) for setup details.

### 1. Get the Template

**Option A: Use as GitHub Template**

1. Click **"Use this template"** → **"Create a new repository"**
2. Clone your new repository

**Option B: Clone Directly**

```bash
git clone https://github.com/YOUR-ORG/YOUR-REPO.git
cd YOUR-REPO
```

