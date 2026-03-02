---
agent: ask
description: "Interactive setup wizard — answer a few questions to generate project configuration files for multi-agent workflows."
---

# Project Setup Wizard

I'll ask you a few questions and then generate your project's configuration files so the multi-agent workflow knows about your codebase.

## Questions

Please answer all of the following. You can adjust the output after:

1. **Project name** — What is this project called? (e.g., "Order Service")
2. **What does it do?** — 1–2 sentences describing the purpose. (e.g., "REST API that manages customer orders for an e-commerce platform.")
3. **Primary language + version** — (e.g., TypeScript 5.x, Java 21, Python 3.12)
4. **Framework + version** — (e.g., Express 4.x, Spring Boot 3.2, FastAPI 0.110)
5. **Database** — (e.g., PostgreSQL 15, MongoDB 7, SQLite, none)
6. **Build tool** — (e.g., npm / tsc, Gradle 8, Poetry)
7. **Test framework** — (e.g., Jest + Supertest, JUnit 5, pytest)
8. **Architecture style** — (e.g., layered MVC, hexagonal, microservices, monolith)
9. **Key conventions** — Any naming rules, patterns, or standards your project must follow? (e.g., "Use constructor injection; all public functions need JSDoc; errors use ApiError class")
10. **Build command** — How do you build? (e.g., `npm run build`)
11. **Run command** — How do you start the dev server? (e.g., `npm run dev`)
12. **Test command** — How do you run tests? (e.g., `npm test`)
13. **Lint/type-check command** — (e.g., `npm run lint && npm run typecheck`)
14. **Quick-validate command** — Fastest check before a PR (usually build + lint combined). (e.g., `npm run build && npm run lint`)

---

## What I'll do with your answers

Once you've provided all answers above, I will:

1. **Generate `.github/copilot-instructions.md`** — create this file with your project overview, tech stack, architecture, conventions, and build commands so agents understand your codebase
2. **Generate `.github/architecture-rules.md`** — create this file with layer structure, dependency rules, testing rules, and naming conventions based on your architecture style and conventions
3. **Confirm** what was created so you can review or adjust

> **Note**: If these files already exist, I'll replace them with your new answers. If you're unsure about any question, give your best guess — you can always edit the files manually afterward. See `examples/` for complete filled-in references (spring-boot-microservice for Java, nodejs-typescript for TypeScript, python for Python).
