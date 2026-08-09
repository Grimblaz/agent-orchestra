---
description: "Open a filed issue for work — one conversation from the filed issue to a lawful brief (routine) or a continuation into design (novel)."
argument-hint: "[issue number]"
---

# /open

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](../CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

<!-- scope: claude-only -->

Run the **open-for-work** flow inline in this conversation for the provided issue. This is the expected entrance for standalone work; `/experience` and `/design` stay reserved as the explicit way to request the phase pipeline, which remains fully lawful.

## Pre-flight

1. **Require an issue number, and require it to be one.** Everything this flow writes — the affirmation record, the amendments, the arm's output artifact — is keyed to a filed issue. The argument must be a **bare positive integer**; anything else (a URL, a title, a shell fragment) is rejected rather than interpreted, because the number is substituted by hand into `gh api` paths later in the flow. If no issue number was supplied, ask for one and stop until it is given. Do not open an unfiled idea for work; ask for it to be filed first (`skills/safe-operations/SKILL.md` §2f states the three required things).
2. **Load the methodology.** Read `skills/open-for-work/SKILL.md` and treat it as the authority for every step: the trivial floor, the worth-it doors, beat 1 and the affirmation gate, the affirmation record's five properties, beat 2's routing rule, both output arms, the escape hatch, resume-state detection, and gate-decision token emission. Resolve it with the plugin-cache-first sequence below.
3. **Check for an existing affirmation record** before running anything. An issue that already carries one resumes rather than restarts — run that section's state decision (`skills/open-for-work/SKILL.md` § Resuming an issue already opened for work), **which owns the full outcome set**, and enter the flow at the state it returns. Not every outcome is a state you enter, and not every state resumes. Two outcomes are reported rather than entered — a routing artifact that predates the issue's **earliest lawful** record is **not lawful under source (b)** (report and stop; that section records why this check has no second home in the repository), and an issue with no lawful record was never opened for work through this flow at all, which for `/open` is simply the ordinary start. Of the four states, `complete` resumes nothing — though it may still owe a close-out record that was already due, in which case write it now and say it is late. Late is the repair, not the norm: the record has two firing moments, and a `complete` issue has passed both. On a run that opens a pull request it is due before the PR-creation action; otherwise — including an issue auto-closed by a keyword in someone else's PR — it is due before the close (`skills/open-for-work/SKILL.md` § Close-out). Take the outcome that section returns; do not force the issue into a state to have one.

### Skill-load halt-on-fail

Resolve and read `skills/open-for-work/SKILL.md` before taking any step of the flow. Use the plugin-cache-first resolution sequence: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `skills/open-for-work/SKILL.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/skills/open-for-work/SKILL.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `skills/open-for-work/SKILL.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`.

If every candidate load fails, emit exactly:

`⚠️ Skill load failed for skills/open-for-work/SKILL.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.`

Then stop. **Do not improvise the flow from this command file, from the doctrine document, or from memory.** This command file is a dispatcher; it deliberately does not restate the methodology, so a run that reaches this branch has nothing to fall back on and must not pretend otherwise.

*(This is the skill-load analogue of `skills/session-startup/SKILL.md` § Step 9's paired-body halt-on-fail. It is stated here rather than folded into Step 9 because Step 9 is scoped to commands that name a paired `agents/{Name}.agent.md` body, and this command names none.)*

## Pre-flight (session-startup)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, and 7b. Step 9 does not apply — this command has no paired agent body; its halt-on-fail is the skill-load block above.

## Inline execution

Run the flow inline in this conversation. Do not dispatch it to a subagent: the affirmation gate needs the person, and both output arms end in this same conversation.

The flow ends in exactly one of five places, and it says which:

- **Below the trivial floor** — fix it directly, no brief, no run ceremony. Rarer than it reads: the floor's risk guard fails closed, so an issue that does not establish that the change avoids permission, authentication, and data-integrity behavior is never below it. The skill decides this, not this list.
- **Park or Decline** at the worth-it doors — recorded, stop.
- **Routine verdict** — a brief persisted as the issue's plan comment under authority source (b), no deviation note.
- **Novel verdict** — this same conversation continues into the design methodology and exits at the standard design-completion marker.
- **Halt** — the methodology could not be loaded (above), or a precondition the skill names is unmet.

Never end a turn having presented the what-statement without asking for affirmation, and never begin beat 2 before it is given.

ARGUMENTS: $ARGUMENTS
