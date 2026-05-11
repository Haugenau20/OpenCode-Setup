---
description: House branch-naming rules. Kind, optional Jira key, short slug.
---

# Branch naming

Format: `<kind>/<jira-key-or-slug>/<short-slug>`

- `<kind>` is one of `feat`, `fix`, `chore`, `refactor`, `docs`.
- Middle segment is either a Jira key (`ABC-1234`) or a free-form slug if
  there is no ticket.
- Final slug is lowercase, hyphenated, <= 5 words, no trailing description.

## Examples

```
feat/ABC-1234/login-mfa
fix/ABC-5678/expired-token-loop
chore/no-ticket/bump-node-20
refactor/payments/extract-money-type
```

## Anti-patterns

- `feature/new-stuff` — vague, no key, wrong kind word.
- `fix-bug` — missing slashes, missing scope.
- `claude/auto-1234abcd` — agent-generated; rename before opening a PR.

Long-lived branches (`main`, `release/*`) are exempt and managed centrally.
