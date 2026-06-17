---
description: Pull the Jira ticket for the current branch (or a given key) into the session as context.
---

Bring the relevant Jira ticket into context so we work against its actual
requirements. Optional argument — a Jira key to use instead of the branch: $ARGUMENTS

Do this, then stop:

1. Decide the issue key:
   - If a key was given as the argument above (matches `[A-Z][A-Z0-9]+-[0-9]+`),
     use it.
   - Otherwise read it from the current branch: run `git branch --show-current`
     and take the middle segment of the house branch format
     `<kind>/<jira-key-or-slug>/<short-slug>` (see the `branch-naming` skill).
     The key matches `[A-Z][A-Z0-9]+-[0-9]+`.
   - If there's no key either way, ask the user for one and stop.

2. Fetch it with the Jira MCP `get_issue` tool (argument `key`). If that tool is
   not available, the Jira MCP is not enabled — tell the user to set
   `JIRA_BASE_URL`, `JIRA_USER`, and `JIRA_PAT` in `.env` and restart, then stop.

3. Summarise the ticket as working context: key + title, type, status, priority,
   assignee, the description, and any linked issues. Quote acceptance criteria
   verbatim if present — that's what we build against.

4. End by asking what the user wants to do with it. Do not modify any files and
   do not start implementing until asked.
