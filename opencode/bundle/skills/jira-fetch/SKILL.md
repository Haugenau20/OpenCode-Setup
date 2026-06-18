---
name: jira-fetch
description: "Fetches issues and search results from the internal Jira server using the Jira MCP tools. Use this skill whenever the user wants to look up, fetch, find, search, or list Jira issues — even if they don't say 'Jira' explicitly. Trigger phrases include but are not limited to: 'get issue XYZ-123', 'fetch VAE-334', 'find all open bugs', 'show me my Jira issues', 'what tickets are assigned to me', 'search Jira for X', 'list issues in project Y'. Always use this skill when a Jira issue key (pattern: [A-Z]+-[0-9]+) is mentioned, or when the user wants to find or list issues."
---

# Jira Fetch Skill

Fetches Jira issues and search results from the internal Jira server using the
available MCP tools, and presents them clearly in the conversation as context
for investigation, planning, or coding tasks.

---

## Available MCP Tools

| Tool                    | What it does                                      |
|-------------------------|---------------------------------------------------|
| `jira_get_issue`        | Fetch a single issue by key, with full details    |
| `jira_search`           | Search issues by JQL, returns compact list        |
| `jira_get_current_user` | Returns the authenticated user's Jira username    |

---

## Workflows

### Fetch a specific issue

When the user provides an issue key (e.g. `VAE-334`):

1. Call `jira_get_issue` with the key
2. Display the full result in the conversation
3. Wait for instructions — do not summarize or suggest next steps

---

### Search for issues

When the user wants to find or list issues:

1. Construct a JQL query from the user's intent (see JQL Guide below)
2. If the query involves the current user (e.g. "my issues", "assigned to me"), call `jira_get_current_user` first to resolve the username, then use it in the JQL
3. Call `jira_search` with the JQL query
4. Display the results
5. Offer to fetch full details on any specific issue: *"Would you like me to fetch the full details of any of these?"*

---

## JQL Guide

Build JQL queries from natural language. Common patterns:

| User says                          | JQL                                                        |
|------------------------------------|------------------------------------------------------------|
| "open bugs in project VAE"         | `project = VAE AND issuetype = Bug AND status = Open`      |
| "my issues" / "assigned to me"     | `assignee = [username from get_current_user]`              |
| "unresolved issues in VAE"         | `project = VAE AND resolution = Unresolved`                |
| "high priority open issues"        | `priority in (High, Highest) AND status = Open`            |
| "issues created this week"         | `created >= -7d`                                           |
| "recently updated in VAE"          | `project = VAE ORDER BY updated DESC`                      |
| "bugs assigned to me in VAE"       | `project = VAE AND issuetype = Bug AND assignee = [name]`  |

Always add `ORDER BY created DESC` if no order is specified, so newest issues appear first.

---

## Rules

- Never ask the user for their Jira username — always resolve it via `jira_get_current_user`
- Never truncate or summarize issue descriptions — display them in full
- Always include the direct Jira URL for every issue shown
- Never suggest writing to Jira (comments, transitions, updates) — this skill is read only
- Do not ask for confirmation before fetching — fetch, then report back
- If a search returns no results, suggest a broader JQL query rather than giving up
