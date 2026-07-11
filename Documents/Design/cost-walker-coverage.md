When a pull request closes an issue, the PR Cost Pattern section should attribute the Claude-side work done for that same issue under `/experience`, `/design`, `/plan`, `/orchestrate`, and `/code-conductor`. That includes upstream phases that happened on `main` before the feature branch existed, so authors of cost-reduction PRs can see the real planning, design, orchestration, and implementation support behind the work they are closing.

## Active attribution rules

Cost attribution currently uses two admission rules for Claude transcript events.

Strict-branch attribution is the baseline rule. Assistant events are included when their working directory matches the repository and their `gitBranch` exactly matches the branch being measured. This remains active even when issue-aware attribution is enabled, so feature-branch implementation work keeps flowing into the PR Cost Pattern section without needing a phase marker.

Phase-marker attribution adds issue-aware coverage for upstream command sessions. When the walker is called with an issue number, a matching command marker opens a window for that issue. Assistant events in that window can be admitted from `main` or from an empty or missing `gitBranch`, as long as their working directory still matches the repository. An empty or missing `gitBranch` does not close an active phase-marker window; a non-empty branch other than `main` does close it.

The supported phase command set is `/experience`, `/design`, `/plan`, `/orchestrate`, and `/code-conductor`, including their `/agent-orchestra:` qualified forms. Phase-marker port hints map `experience` to `experience`, `design` to `design`, and `plan` to `plan`; `orchestrate` and `code-conductor` map to `orchestrator-overhead` for no-dispatch parent turns. If an admitted assistant event contains an Agent dispatch, dispatch attribution wins over the phase-marker default.

### Maintainer marker details

Claude user transcript events must carry a command marker in the form `<command-name>/{command}</command-name>` followed by `<command-args>{issue}</command-args>`. The command must be one of the supported phase commands, and the issue argument must be a bare number, `#{number}`, or `issue {number}`. Other tag names, object-array user content, freeform prompt text, or malformed arguments do not open a phase-marker window.

Phase windows are scoped to one JSONL file. A marker in one transcript file does not carry over into another file in the same project slug directory.

### Rolling-baseline eligibility

Attribution decides whether a walked event is counted; baseline eligibility is a separate, downstream decision about whether a counted capture is trustworthy enough to feed the rolling-history baseline. `Resolve-BaselineEligibility` (`.github/scripts/lib/cost-completeness.ps1`) wraps `Get-SessionCompleteness` (unchanged) and augments its result in place with a `capture_point` disclosure.

Before this mechanism existed, any session captured mid-work — for example at PR-creation time, before the session had actually ended — was always excluded from the baseline, because its transcript tail was an unresolved `tool_use` and therefore classified `partial`. `Resolve-BaselineEligibility` admits such captures when they carry real (non-zero) token data, labeling them `capture_point: pr-creation-mid-session` in the persisted cost-comment YAML. A session whose transcript tail genuinely finished is labeled `capture_point: end-of-session`.

Eligibility is a strict whitelist, not a relaxation of the existing guards: `stop_reason` must be `tool_use`, `null`, or empty, and the session must carry non-zero tokens. The four named partial reasons (`refusal`, `pause_turn`, `max_tokens`, `stop_sequence`) and zero-token captures remain always excluded — the "zeros pin" guard from #777 is untouched. Phase-marker-only sessions (see Known gaps) are also excluded from mid-session eligibility, matching the existing exclusion for complete sessions.

A later session-startup step (`skills/session-startup/SKILL.md` Step 7d, Claude-only) calls `Invoke-CostBaselineHarvest` (`.github/scripts/lib/cost-baseline-harvest.ps1`) to opportunistically upgrade these mid-session estimates. It looks for recently-merged PRs whose cost comment still says `capture_point: pr-creation-mid-session`, and — only once it verifies the originating transcript still exists locally and the PR is confirmed still merged — re-walks that session and replaces the comment in place with exact `capture_point: end-of-session` numbers. This is best-effort and bounded: a ~14-day candidate horizon and at most one re-walk attempt per session startup.

## Ambiguous-prompt fallback

Non-canonical surfaces fall back to the strict branch filter. That includes subagent-name dispatch such as `@Experience-Owner`, freeform prompts like asking for planning in prose, and resume-via-marker flows that do not produce the canonical command marker tags in the Claude JSONL user event.

This fallback is intentional: when the transcript does not prove both the command surface and target issue in the expected marker shape, the walker avoids guessing and attributes only events that match the measured branch directly.

## Known gaps

Subagent-name dispatch remains a known gap because `@Experience-Owner`, `@Solution-Designer`, and related direct agent calls do not currently produce the canonical command-marker tags that phase-marker attribution consumes. That follow-up belongs with [#488](https://github.com/Grimblaz/agent-orchestra/issues/488).

Freeform and resume-via-marker sessions can also miss upstream attribution when they do not emit the canonical command marker. They still contribute through strict-branch attribution if their assistant events occurred on the measured branch.

Phase-marker-only sessions are excluded from rolling-history baselines. They can be complete and still stay out of the baseline because they contain attributed assistant work for the issue but no assistant events on the measured branch. This exclusion also holds for the mid-session eligibility predicate described under Rolling-baseline eligibility above — a phase-marker-only session never qualifies for baseline inclusion, complete or partial.

## Rejected alternatives summary

The branch-creation window alternative was rejected because it can pull unrelated work into the current PR whenever multiple issues share `main` history before a feature branch exists. That creates cross-issue contamination instead of issue-specific attribution.

The status quo was rejected because strict branch filtering alone fails the acceptance criteria for upstream phases. It misses `/experience`, `/design`, and `/plan` work performed on `main` before the feature branch was created, which leaves the PR Cost Pattern section under-attributed for the issue it closes.

Parity test note: if AC5 or the required documentation sections change, update `.github/scripts/Tests/cost-walker-coverage-doc.Tests.ps1` in the same commit.

<!-- markdownlint-disable-file MD041 -->
