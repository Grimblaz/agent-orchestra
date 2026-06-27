---
name: naming-register-policy
description: "Two-register naming policy for agent-orchestra: rules for when machine codes stay as-is vs get human names or first-use expansion. Use when authoring human-facing prose, sweeping rename-candidates, or resolving what a code like SMC-20 means. DO NOT USE FOR: deciding whether to create new vocabulary (use design-exploration), auditing docs for general readability (use ai-first-documentation for agent docs or #750/#751 for human docs)."
---

<!-- markdownlint-disable-file MD041 MD003 -->

# Naming Register Policy

Two-register naming policy for agent-orchestra. Classifies the 48 v1 vocab-seed terms and defines rules for when machine codes stay as-is versus when they require human names or first-use expansion.

## When to Use

Load this skill when:

- Authoring or editing any human-facing prose surface (`CLAUDE.md`, READMEs, `HOW-IT-WORKS.md`, skill `description:` frontmatter, `Documents/Design/` orientation docs, issue/PR templates)
- Running a rename-candidate sweep (e.g., the #750 worklist)
- Resolving what a code token like `SMC-20` or `D3` means in context
- Deciding whether a term in human-facing prose needs expansion

### DO NOT USE FOR

- **Creating new vocabulary or naming new concepts** — use `skills/design-exploration/SKILL.md` for decisions about whether a new term is needed
- **General readability auditing of agent-facing docs** — use `skills/ai-first-documentation/SKILL.md`
- **Auditing or rewriting human-facing docs** — this is the scope of #750 (closed worklist sweep) and #751 (growth enforcement), not this skill

## Two-Register Rules

This skill defines a two-register policy: machine-citation contexts preserve stable codes; human-facing prose uses self-describing names or expands codes on first use.

1. **Two registers exist.** Machine-citation contexts keep stable codes; human-facing prose uses self-describing names or expands the code on first use.
2. **Machine-citation contexts** — cross-references, durable markers (`<!-- plan-issue-{ID} -->`), automation keys, config field names, YAML field names in structured blocks, skill names in `adapter:` and `executor:` frontmatter. Stable codes are preserved here.
3. **Human-facing prose** — `CLAUDE.md`, READMEs, skill `description:` frontmatter, `Documents/Design/` orientation docs, issue and PR templates, `HOW-IT-WORKS.md`. Here use self-describing names or expand codes on first use.
4. **Keep good metaphors.** Terms like `prosecution / defense / judge` are already self-describing and require no expansion in any context.

## Taxonomy

Three classification tiers form the `register` field values in `register.json`:

- **`stable-code`** — Has a real machine-anchor role (durable marker, cross-reference, automation key). Examples: `SMC-NN`, `plan-issue-{ID}`, `credits[]`. Behavior: keep the code in machine-citation contexts; expand on first use in human-facing prose. The expansion text is in the `expansion` field of the register entry.
- **`self-describing`** — Already human-readable; no action needed. Examples: `prosecution / defense / judge`, `Experience-Owner`, `adversarial review`. Behavior: use as-is everywhere; these terms do not require expansion in either register.
- **`rename-candidate`** — Pure prose jargon with no machine-anchor role; the code has no value in machine contexts and only obscures human-facing prose. Examples: `Value Reflex`, `now-coupled / wall-clock dependent`. Behavior: replace with the `replacement` field value in human-facing prose. These rows form **#750's closed backfill worklist**.

## Numbered-Family Decode Rule

When a term covers a *numbered family* of instances (e.g., `SMC-NN` covers SMC-01 through SMC-23), the register carries a single family row rather than one row per instance. Family rows are identified by `kind: family` in `register.json`.

To keep a reader who encounters a *specific* instance (e.g., `SMC-20`) from staying stuck, every numbered-family row carries a `decode` field pointing to the resolution home:

> *"SMC-NN = Session Memory Contract rule NN; the full numbered list is in `skills/session-memory-contract/SKILL.md`."*

To resolve a specific instance: find the family row whose `term` pattern matches the instance token, then follow the `decode` field to the resolution home.

## Reader ≤1-Hop Escape Hatch

Every human-facing surface that uses a stable code must offer an escape-hatch path to a definition within one hop. This is the **≤1-hop** reader escape-hatch rule.

Examples of compliant one-hop paths:

- An issue or PR template footer pointing at `HOW-IT-WORKS.md` §5
- A `CLAUDE.md` section heading that links to the full reference skill
- A code's first use followed by its expansion in parentheses (e.g., "SMC-01 (the session-memory-contract rule for plan persistence)")

A reader who encounters an un-expanded stable code in human-facing prose must always have a discoverable definition home within one hop. This rule applies to all `stable-code` entries when used in human-facing prose surfaces.

## Human-Facing Prose Surfaces

These surfaces follow the two-register rules (use self-describing names or expand on first use):

- `CLAUDE.md`
- READMEs (repo root and subdirectory)
- Skill `description:` frontmatter
- `Documents/Design/` orientation docs
- Issue and PR templates
- `HOW-IT-WORKS.md` and other user-facing documentation

Machine-citation contexts (where stable codes are preserved): HTML comment markers in GitHub comments, YAML field names in structured blocks, config file keys, skill names in `adapter:` and `executor:` frontmatter.

## Child Boundary Contract

The register's v1 scope is the 48 vocab-seed rows from `HOW-IT-WORKS.md` §5. This creates two distinct worklists:

- **#750's closed worklist** — The `rename-candidate` rows in this register. #750 backtracks through the living reader surface (`CLAUDE.md`, READMEs, templates) and replaces each `rename-candidate` with its `replacement` field value. The set is bounded: #750 works only from this register, not from a broader survey.
- **#751's open set** — New codes introduced after this register ships. #751's newcomer-audit detector enforces "grow on introduction": any new system term introduced in human-facing prose must be either self-describing or expanded on first use. Growth enforcement is #751's responsibility, not this skill's.

Terms not in the v1 register that appear in human-facing prose are in #751's domain.

## #693 Coordination

#693 is a sibling umbrella that optimizes agent-facing docs *for agents* (machine-citable codes, SMC-NN/D-numbers praised for precision). #732 optimizes *for humans* and owns reconciling the two registers.

One settled rule: **`stable-code` terms stay as stable codes in machine-citation contexts; the human layer (vocab-seed + first-use expansions) translates them.** #750's rename sweep operates **only** on `rename-candidate` rows and **sequences after** #693's naming-related pieces (#695/#696) on any shared file.

**Deferred (not yet in tree):** The concrete shared-file manifest listing which files #695/#696 and #750 both touch is deferred until #695/#696 edit-scope is designed. The sequencing rule above is the contract in the interim. The manifest will be added here when #695/#696 scope is established.

## One-Way Binding Declaration

The register asset (`register.json`) is **one-way bound** to the vocab-seed term set in `HOW-IT-WORKS.md` §5. The binding declaration is:

- The register is **keyed by vocab-seed terms** — each `register.json` `term` field is the verbatim bold-cell key from the vocab-seed table.
- The vocab-seed does **not** carry register classification — the reader-facing table remains a clean 3-column `Term | Plain meaning | Where it appears` table.
- The binding direction is intentional: the vocab-seed is the canonical human-readable source; the register is the machine-readable classification layer on top of it.

To read the register for a term: load `register.json`, find the entry where `term` equals the exact vocab-seed key, and use the `register`, `expansion`, `replacement`, and/or `decode` fields as appropriate for the context.

## Scope & Boundaries

**What this skill does:**

- Defines the two-register policy rules
- Classifies the 48 v1 vocab-seed terms
- Provides the decode rule for numbered-family tokens
- Defines the #750 closed worklist (rename-candidate rows) and the #751 open-set boundary

**What this skill does NOT close:**

This skill — and issue #732 as a whole — **does not** by itself close the S1 scenario ("a stuck GitHub reader becomes self-sufficient"). S1 requires:

- **#750**: the active rename-candidate sweep through `CLAUDE.md`, READMEs, and templates
- **#751**: the outsider-first authoring default and growth-enforcement newcomer-audit detector
- The first-use expansion rule applied in practice to human-facing prose

Without #750 and #751 landing, a GitHub reader hitting an issue will still encounter opaque codes. The policy and register are prerequisites, not sufficient conditions. S1 remains on-issue until #750 and #751 close.

## Frame Ports

This skill is **supporting methodology** — it is loaded by authoring agents (#750's sweep, #751's newcomer-audit detector, any agent producing human-facing prose) to resolve term classifications and apply the two-register rules. It does **not** declare `provides:` because it does not fill a Frame Port directly.

Consumers load this skill with:

```
Use `skills/naming-register-policy/SKILL.md` to apply the two-register rules and resolve term classifications from `register.json`.
```
