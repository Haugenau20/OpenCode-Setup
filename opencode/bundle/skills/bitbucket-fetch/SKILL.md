---
name: bitbucket-fetch
description: "Fetches code context from the internal Bitbucket server using the Bitbucket MCP tools — projects, repos, commits, pull requests (with review comments), and file contents. Use whenever the user wants to look up, fetch, find, search, browse, or cross-reference Bitbucket — even if they don't say 'Bitbucket' explicitly. Especially for the Jira → Bitbucket cross-reference: tracing a ticket to the commits/PRs that implemented it, reading a PR's diff or review discussion, finding which PR introduced a change, or reading a source file at a given ref. Trigger phrases include 'find the PR for PROJ-123', 'what changed in repo X', 'show commits mentioning VAE-45', 'read file Y from repo Z', 'why was this implemented this way'. Read-only."
---

# Bitbucket MCP — Agent Skill

Use the Bitbucket MCP server when you need **code context** to supplement a
Jira issue or answer a technical question about the codebase. The primary
workflow is **Jira → Bitbucket cross-reference**: start with a Jira issue,
then use Bitbucket to find related commits, PRs, and source code.

---

## Workflow patterns

### 0. Finding the right project and repo (when not already known)

```
1. bitbucket_list_projects              → get all project keys and display names
2. bitbucket_list_repos(projectKey=...) → get all repo slugs in that project
```

Always run this first if the user hasn't supplied an exact projectKey and repoSlug.

### 1. Tracing a Jira issue to code changes

```
1. jira_get_issue                            → understand the ticket
2. bitbucket_get_commits(query="PROJ-123")   → find commits that mention the ticket key
3. bitbucket_get_pull_requests(state="MERGED") → list merged PRs around the same time
4. bitbucket_get_pull_request(prId=...)      → read review discussion for context
5. bitbucket_get_file(filePath=...)          → read the affected source file
```

### 2. Understanding why something was implemented a certain way

```
1. bitbucket_get_file        → read the current source code
2. bitbucket_get_commits     → find who changed this file and when
3. bitbucket_get_pull_request → read the PR description and review comments for rationale
```

### 3. Finding which PR introduced a bug

```
1. bitbucket_get_commits(branch="main", query="feature-x") → narrow down the range
2. bitbucket_get_pull_requests(state="MERGED")             → list candidates
3. bitbucket_get_pull_request                              → inspect diff refs and review notes
```

---

## Tool reference

### `bitbucket_list_projects`
- No required args. Call this when the project key is unknown.
- Returns: key, name, description for every accessible project.

### `bitbucket_list_repos`
- Requires `projectKey`. Call this when the repo slug is unknown.
- Returns: slug, name, description, state, defaultBranch.
- The `slug` value is what all other tools expect as `repoSlug`.

### `bitbucket_get_commits`
- **Best first tool** — lightweight, gives commit messages and authors fast.
- Use `query` to filter by Jira ticket key (e.g. `"PROJ-123"`).
- Use `branch` to scope to a specific branch.
- Returns: id, displayId, message, author, timestamp, parents.

### `bitbucket_get_pull_requests`
- Lists PRs for a repo. Default state is `OPEN`; use `MERGED` for history.
- Returns: id, title, state, author, branch names, reviewers, description snippet.

### `bitbucket_get_pull_request`
- Fetches a single PR **including all review comments**.
- Use after `bitbucket_get_pull_requests` to deep-dive into the most relevant one.
- Returns: full description, fromBranch/toCommit, reviewers with approval status, comment thread.

### `bitbucket_get_file`
- Fetches full file contents at a branch/tag/commit ref.
- Use `ref` to pin to the exact commit from a related commit ID if you need historical context.
- Large files are paginated and reassembled automatically.

---

## Key parameters

| Parameter    | Description                                      | Example           |
|-------------|--------------------------------------------------|-------------------|
| projectKey  | Bitbucket project key — use `bitbucket_list_projects` if unknown | `MYPROJ`    |
| repoSlug    | Repo slug — use `bitbucket_list_repos` if unknown | `payment-service` |
| branch      | Branch name or commit hash                       | `main`, `release/2.4` |
| query       | String to match in commit messages               | `PROJ-456`        |
| prId        | Numeric pull request ID                          | `42`              |
| filePath    | Path from repo root, no leading slash            | `src/App.java`    |
| ref         | Branch, tag, or commit SHA for `bitbucket_get_file` | `abc1234`      |

---

## Tips

- **Always search commits with the Jira key first** — it's the fastest way to
  link a ticket to a code change.
- Commit `displayId` (short hash) is useful for `bitbucket_get_file ref=` to pin
  to an exact moment in history.
- If `bitbucket_get_commits` returns nothing for a ticket key, try a keyword from
  the ticket title instead.
- PR review comments often contain the *rationale* for implementation choices
  that aren't in the commit message — always check them for "why" questions.
- `bitbucket_get_file` on a config file (e.g. `pom.xml`, `build.gradle`,
  `Dockerfile`) is useful for understanding dependencies and build setup.
