---
name: frontend-design
description: Guide for creating distinctive UI designs that avoid generic templates. Use when designing new UI components, screens, or evaluating designs for uniqueness and purpose.
---

# Frontend Design Skill

Guide for creating distinctive, purposeful UI designs that avoid cookie-cutter patterns.

## When to Use

- Designing new UI components or screens
- Evaluating existing designs for uniqueness
- Reviewing designs that feel "generic"
- Creating brand-aligned interfaces
- Building memorable user experiences

## Core Principles

### 1. Purpose Over Pattern
Every design decision should answer: "Why this, not something else?"

- **Bad**: Using a card grid because it's common
- **Good**: Using a card grid because content is comparable and scannable

### 2. Distinctive Identity
Your UI should be recognizable without the logo.

Questions to ask:
- Would users recognize this as our product?
- What makes this different from competitors?
- Does this reflect our brand personality?

### 3. Intentional Defaults
Don't accept framework defaults blindly.

```
[CUSTOMIZE] Review these common defaults in your stack:
- Border radius values
- Shadow depths
- Spacing scales
- Color applications
- Typography scales
```

## Design Review Checklist

### Visual Distinction
- [ ] Color palette goes beyond primary/secondary/neutral
- [ ] Typography creates clear hierarchy (not just size changes)
- [ ] Spacing creates intentional rhythm (not uniform gaps)
- [ ] Icons have consistent style/weight/meaning
- [ ] Micro-interactions add personality

### Purposeful Patterns
- [ ] Each component solves a specific user problem
- [ ] Layout serves content structure (not vice versa)
- [ ] Navigation reflects user mental models
- [ ] Empty states guide users (not just "No data")
- [ ] Loading states reduce perceived wait time

### Avoiding Generic Traps
- [ ] Not using component library defaults unchanged
- [ ] Headers aren't just logo-left, nav-right
- [ ] Forms have personality beyond labels + inputs
- [ ] Buttons vary by importance (not just color)
- [ ] Data displays fit the data (not just tables)

## Breaking Generic Patterns

### Instead of Generic Cards
Consider:
- Asymmetric layouts for visual interest
- Inline expansion vs. navigation
- Progressive disclosure of details
- Content-specific shapes (not all rectangles)

### Instead of Generic Forms
Consider:
- Conversational flows for complex inputs
- Smart defaults that reduce input
- Inline validation with helpful context
- Progress indication for multi-step

### Instead of Generic Tables
Consider:
- Is a table the right pattern at all?
- Grouped/nested rows for hierarchy
- Inline actions vs. row selection
- Responsive transformations (not just scroll)

### Instead of Generic Dashboards
Consider:
- User goals, not data availability
- Actionable metrics, not vanity metrics
- Contextual insights, not just numbers
- Personalization based on role/usage

## Design Language Documentation

[CUSTOMIZE] Document your design language:

```markdown
## Our Design Personality
- [Define 3-5 adjectives: e.g., "Professional but approachable"]

## Signature Elements
- [Unique visual elements that define your brand]

## Intentional Constraints
- [Self-imposed rules that create consistency]

## Anti-Patterns
- [Specific patterns to avoid in your context]
```

## Review Questions

Before shipping any design:

1. **Is this recognizable?** Would users know it's from us?
2. **Is this purposeful?** Can we justify every choice?
3. **Is this necessary?** Does it solve a real problem?
4. **Is this accessible?** Can all users interact with it?
5. **Is this maintainable?** Can we scale this pattern?

## Resources

[CUSTOMIZE] Add your project's design resources:
- Design system documentation
- Brand guidelines
- Component library
- Design tokens
- Approved patterns and templates
