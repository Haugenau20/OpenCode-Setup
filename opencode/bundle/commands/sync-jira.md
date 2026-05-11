---
description: (disabled) Pull the linked Jira ticket into the session context.
disabled: true
---

This is a placeholder for the future Jira integration. It is shipped
disabled so it does not show up in the slash-command palette until the
backend is wired.

When enabled, the command will:

1. Read the Jira key from the current branch (`branch-naming` skill).
2. Fetch the issue summary, description, and acceptance criteria via the
   already-allowlisted internal Jira host.
3. Inject the result as a system message at the top of the session.

Do not remove the `disabled: true` front-matter key until the Jira API
client, redaction policy, and rate-limit story are signed off.
