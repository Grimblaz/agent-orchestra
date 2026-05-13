# Platform Routing Notes

Fixture for hub-artifact-paths extraction grammar tests — platforms scope
(simulating `skills/*/platforms/*.md`).

## Claude-specific invocation

Before dispatching, load `skills/upstream-onboarding/SKILL.md` for the
onboarding methodology.

The agent body lives at `agents/Experience-Owner.agent.md` and is resolved
from the plugin cache per the D1 resolution order.

## Excluded patterns (must NOT be extracted)

Marker template: <!-- experience-owner-complete-{ID} -->
Tool name: `Agent`
URL: https://github.com/Grimblaz/agent-orchestra/issues/369
