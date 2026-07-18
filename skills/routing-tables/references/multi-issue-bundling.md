# Multi-Issue Bundling and Dispatch Notes

Extracted detail supporting `agents/Code-Conductor.agent.md` § Multi-Issue Bundling and § Agent Selection. Code-Conductor keeps the bundle-classification and specialist-selection rules in its own body; this reference carries the surrounding rationale and edge-case detail.

## Per-issue scope classification (bundle rule)

Classify each issue separately using the Scope Classification Gate rubric. The bundle adopts the **highest-scope tier** (if any issue requires full pipeline, run full pipeline for all).

**Bundle rule**: the bundle announces (no question) only when EVERY bundled issue's outcome is determined — list each issue's tier and the deciding criteria, followed by the 'highest-scope-wins' bundle tier. If ANY bundled issue is indeterminate, the existing single combined question fires for the whole bundle unchanged: present all issue classifications in a single `#tool:vscode/askQuestions` call — do not make separate per-issue prompts, formatting the recommendation as a list entry per issue showing recommended tier and the key criterion driving the classification, followed by the 'highest-scope-wins' bundle tier.

## Agent Selection dispatch notes

**native Explore vs Research-Agent**: Use the native Explore subagent for lightweight read-only fact-finding (runs on a fast model in a short-lived context — the returned summary is typically smaller than running equivalent tool calls inline). Use Research-Agent when analysis is deep/multi-file and the result needs to be persisted to a research document for future reference. When in doubt: Explore for discovery, Research-Agent for output that must survive compaction. The underlying split rule is canonically defined in `research-methodology` § Two-Layer Research Delegation; this note is an operational reminder for Code-Conductor dispatch, not a duplicate authority.

**Doc-Keeper parallel documentation batches**: When delegating multiple documentation file updates to Doc-Keeper in a single batch, include a per-file self-check instruction in the delegation prompt: after writing each file, Doc-Keeper should run that file's own Requirement Contract validation grep before proceeding to the next file. The global final validation scan is then a confirmation pass, not the first opportunity to detect gaps.

**Senior Engineer**: Senior Engineer (spine-driven default executor for skill-as-adapter slices) is invoked from frame-slice `executor:` metadata, not ad hoc prose-trigger routing.
