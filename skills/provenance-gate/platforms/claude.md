# Platform — Claude Code

The `provenance-gate` developer gate invokes Claude Code's `AskUserQuestion` tool. Pass the assessment summary as the prompt and these option labels verbatim (SKILL.md expects them for branch-on-response):

1. `I wrote this / I'm fully briefed`
2. `Assessment looks right - proceed with caution`
3. `Needs rework - stop here`

Claude Code returns the selected label string.
