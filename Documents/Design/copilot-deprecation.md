# Copilot / VS Code Deprecation

> **Status:** Frozen as of 2026-06 — present but unmaintained. Retiring after 2026-08-31 unless someone reaches out.

## What this means

GitHub Copilot (VS Code) support is **frozen** — no new features, no bug fixes, no parity updates.
The platform is present and usable as-is, but will be **retired after 2026-08-31**.

**Claude Code** is the actively maintained and supported path.

## If you depend on Copilot support

If you depend on the Copilot/VS Code surface, start a **[GitHub Discussion](https://github.com/Grimblaz/agent-orchestra/discussions)** in this repo before 2026-08-31. A genuine reach-out may prompt the maintainer to reconsider retirement — though there is no committed monitoring loop and no guarantee of reconsideration.

Fallback: if Discussions are unavailable or you don't get a response, open an issue on [Grimblaz/agent-orchestra](https://github.com/Grimblaz/agent-orchestra/issues).

## Reversibility

This is a policy + labeling change only — nothing was deleted. The Copilot surfaces are in the repository and git-revertible. Moving to full removal (after the sunset date) would be a separate, deliberate decision.

Additive banners (this doc, the README banner) are cleanly removable. In-place edits (VS Code install section rewrite, test de-obligations) are git-revertible but not toggle-clean — restoring Copilot parity would require re-enabling skipped tests and updating affected docs.

## Why this decision was made

Running this token-heavy multi-agent pipeline through GitHub Copilot's premium/agent-request billing became cost-prohibitive. The maintainer moved to Claude Code exclusively. The dual-platform parity tax (building and testing every feature twice) has no return on an unused platform.

See [issue #651](https://github.com/Grimblaz/agent-orchestra/issues/651) for the full design decision record.

## For contributors and agents

The signal to look for: if you're about to invest effort on a `.github/prompts/*.prompt.md` or a `platforms/copilot.md` — **stop**. That work is frozen. Build the Claude surface only.
