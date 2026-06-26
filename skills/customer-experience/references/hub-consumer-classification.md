<!-- markdownlint-disable-file MD041 MD003 -->

# Hub/Consumer Classification Gate

Extracted from `skills/customer-experience/SKILL.md` (`## Hub/Consumer Classification Gate`). Run this gate once per issue before finalizing upstream framing.

Before finalizing upstream framing, classify whether the issue proposes adding content that primarily manifests in one language's type system, runtime, or framework to a hub agent (any `.agent.md` in `agents/`). Hub agents are language-agnostic - language-specific review rules, prosecution perspectives, and behavioral patterns belong in consumer-repo artifacts:

- **Review rules / pitfalls** -> `examples/{stack}/architecture-rules.md`
- **Stack-specific conventions** -> `examples/{stack}/copilot-instructions.md`
- **Reusable cross-stack skills** -> `skills/{skill-name}/`

If the gate fires, redirect the proposal to the appropriate consumer artifact and reframe the issue accordingly. The user may override with explicit rationale if the proposed content is genuinely language-agnostic.

This gate applies equally to upstream framing (Experience-Owner) and downstream design exploration (Solution-Designer); run it once per issue and carry the result forward.
