<!-- markdownlint-disable-file MD041 MD003 -->

# Sources, Verification Record, and Open Gaps

Evidence record behind [rubric.md](./rubric.md). Two deep-research passes (June 2026), each with parallel multi-angle search, source fetching, and 3-vote adversarial verification per claim. Pass 1: 23 sources, 115 claims extracted, 25 verified (24 confirmed, 1 refuted). Pass 2: 26 sources, 128 claims extracted, 25 verified (22 confirmed, 3 refuted). All surviving claims were live-verified against their sources on **2026-06-10/11**.

## Table of Contents

- [Tier 1 — Anthropic official](#tier-1--anthropic-official)
- [Tier 2 — Major vendor guidance](#tier-2--major-vendor-guidance)
- [Tier 3 — Evidenced practitioners and research](#tier-3--evidenced-practitioners-and-research)
- [Refuted claims (do not carry forward)](#refuted-claims-do-not-carry-forward)
- [Confirmed open gaps](#confirmed-open-gaps)
- [Re-verification guidance](#re-verification-guidance)

## Tier 1 — Anthropic official

| Source | Backs rubric items |
| --- | --- |
| [Claude Code best practices](https://code.claude.com/docs/en/best-practices) | A1–A4, A8, B1, F1 |
| [Claude Code memory](https://code.claude.com/docs/en/memory) | A2–A4, A8, A9, E2 |
| [Agent Skills best practices](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices) (redirects to platform.claude.com) | B1–B5, B7, B8 |
| [Engineering: effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) | Core principle, A1, D1–D3, F1 |
| [Engineering: equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) | B1, B2, B6, B7 |
| [Claude Code sub-agents](https://code.claude.com/docs/en/sub-agents) | C1–C4 |
| [anthropics/skills repo](https://github.com/anthropics/skills) | B3, B4 (corroboration) |

Key verified quotes: the deletion test ("Would removing this cause Claude to make mistakes?... Bloated CLAUDE.md files cause Claude to ignore your actual instructions!"); "target under 200 lines per CLAUDE.md file"; "Keep SKILL.md body under 500 lines"; "Keep references one level deep"; the hybrid retrieval model ("CLAUDE.md files are naively dropped into context up front, while primitives like glob and grep... bypass the issues of stale indexing").

## Tier 2 — Major vendor guidance

| Source | Backs rubric items |
| --- | --- |
| [agents.md spec](https://agents.md/) | E1 (60k+ claimed; ~95k independently verified via GitHub code search) |
| [GitHub Blog: lessons from 2,500+ AGENTS.md files](https://github.blog/ai-and-ml/github-copilot/how-to-write-a-great-agents-md-lessons-from-over-2500-repositories/) | A5, A6 |
| [GitHub Docs: response customization](https://docs.github.com/en/copilot/concepts/prompting/response-customization) | E3, E4, E7, E8 |
| [GitHub Docs: custom-instructions support matrix](https://docs.github.com/en/copilot/reference/custom-instructions-support) | E3, E7 |
| [GitHub Docs: customize code review](https://docs.github.com/en/copilot/tutorials/customize-code-review) | E4 |
| [Cursor rules docs](https://cursor.com/docs/rules) | E5; <500-line rule-file ceiling |
| [OpenAI Codex: AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md) | E6 |
| [OpenAI Codex: best practices](https://developers.openai.com/codex/learn/best-practices) | A7, F2 ("A short, accurate AGENTS.md is more useful than a long file full of vague rules") |

## Tier 3 — Evidenced practitioners and research

| Source | Backs rubric items | Evidence quality |
| --- | --- | --- |
| [Cloudflare: internal AI engineering stack](https://blog.cloudflare.com/internal-ai-engineering-stack/) (Apr 2026) | F3, F4 | n = 1 org, ~3,900 repos, self-reported; deployed pattern, not measured effectiveness |
| [HumanLayer production CLAUDE.md](https://github.com/humanlayer/humanlayer/blob/main/CLAUDE.md) | A1, A2 confirmation | n = 1 repo; independently measured at 88 lines, 7 sections, deliberate pruning commits |
| [arXiv 2604.03515: taxonomy of 13 open-source coding agents](https://arxiv.org/pdf/2604.03515) (Apr 2026) | F1 corroboration | Single-author preprint; open-source agents only — Cursor (proprietary) uses pre-built embedding indexes |
| [Cline rules docs](https://docs.cline.bot/customization/cline-rules) | E1 corroboration (reads .cursorrules, .windsurfrules, AGENTS.md) | Vendor doc |

## Refuted claims (do not carry forward)

Adversarial verification killed these plausible-sounding claims; do not let them re-enter the canon:

1. **"File metadata (names, sizes, timestamps) functions as freshness/relevance signals for agents"** — refuted 0-3. There is no verified freshness-signal prescription from Anthropic.
2. **"AGENTS.md is the only universally honored instruction format across Copilot surfaces"** — refuted 0-3. Support is genuinely uneven per surface.
3. **"Codex's 32 KiB cap constitutes a divergence from minimalism"** — refuted 0-3. The cap is a loading budget, not content guidance; OpenAI's content guidance is explicitly minimalist.
4. **"Directory-scoped AGENTS.md overrides are OpenAI's official monorepo scoping prescription"** — refuted 0-3. The layered root-down merge is documented; the monorepo prescription framing is not.

## Confirmed open gaps

Two independent research passes converged on the same list. No credible Tier 1–3 guidance survived verification for:

- How to author ADRs, design docs, and runbooks differently when an AI agent is a primary reader
- Whether llms.txt-style indexes/manifests help or hurt vs. pure just-in-time glob/grep search (no comparative evidence exists)
- Docs-as-skills: wrapping general project docs in SKILL.md beyond Anthropic's settled skills canon
- Doc-to-code / code-to-doc linking conventions that break loudly on drift
- Directory structure and naming conventions for doc trees optimized for agent navigation

Sharpest unresolved cross-vendor question: does GitHub's warning against pointer references (rubric E8) hold for same-repo progressive-disclosure pointers? The doc's own example is cross-repo; no measured evidence either way.

## Re-verification guidance

Vendor documentation churns. Before enforcing any concrete number as a hard gate, re-verify against the live source — particularly: the Copilot 4,000-character code-review limit (had a Feb-2026 docs-churn episode); the Claude Code AGENTS.md non-support status (open feature request with 5,200+ reactions — if native support lands, the `@AGENTS.md` shim pattern becomes legacy); and the docs.claude.com → platform.claude.com skill-page redirects. The 200-line and 500-line targets are quality recommendations, not enforced limits, and should be treated as adherence guidance rather than CI failures.
