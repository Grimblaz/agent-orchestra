<!-- markdownlint-disable-file MD041 MD003 -->

# Proxy Prosecution Mode

Mode file for `proxy_prosecution`. Loaded selector-conditionally alongside the shared core in [../SKILL.md](../SKILL.md) — see that file's § Mode-Scoped Loading. A dispatch in another mode must not load this file.

## Proxy Prosecution Workflow

When representing an external review ledger:

- Treat the ingested reviewer comments as the authoritative scope
- Validate each claim rather than generating a fresh review
- Preserve the no-net-new rule unless an unavoidable critical blocker appears
- Attribute findings to the external reviewer rather than the current agent
