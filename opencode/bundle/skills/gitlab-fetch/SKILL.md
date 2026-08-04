---
name: gitlab-fetch
description: "Fetches code context from the internal GitLab instance using the GitLab MCP tools — projects, commits, merge requests (with review comments/notes), MR diffs and changed files, and file contents. Use whenever the user wants to look up, fetch, find, search, browse, or cross-reference GitLab — even if they don't say 'GitLab' explicitly. Especially for the Jira → GitLab cross-reference: tracing a ticket to the commits/MRs that implemented it, reading an MR's diff or review discussion, finding which MR introduced a change, or reading a source file at a given ref. Trigger phrases include 'find the MR for PROJ-123', 'what changed in project X', 'show commits mentioning VAE-45', 'read file Y from gitlab repo Z', 'why was this implemented this way'. Also covers GitLab issues (read, and comment/create when writes are enabled) and opening or updating merge requests during unattended runs."
---

# GitLab MCP — Agent Skill

Use the GitLab MCP server when you need **code context** to supplement a
Jira issue or answer a technical question about the codebase. The primary
workflow is **Jira → GitLab cross-reference**: start with a Jira issue,
then use GitLab to find related commits, merge requests, and source code.

In GitLab, a **project** is the repository itself — there is no separate
project-vs-repo lookup like Bitbucket. Projects are identified by a numeric
ID or by their URL-encoded path (`namespace/path`). Pull requests are called
**merge requests** (MRs), and they're referenced by their **iid** (internal
ID, scoped to the project), not a global ID.

---

## Workflow patterns

### 0. Finding the right project (when not already known)

```
1. gitlab_list_projects(search="...") → find projects by name/path
```

Returns id, path_with_namespace, name, description, default_branch, web_url.
Always run this first if the user hasn't supplied an exact project ID or
`namespace/path`. Use the `id` or `path_with_namespace` as the `project`
argument for every other tool.

### 1. Tracing a Jira issue to code changes

```
1. jira_get_issue                                  → understand the ticket
2. gitlab_get_commits(project, query="PROJ-123")   → find commits that mention the ticket key
3. gitlab_get_merge_requests(project, state="merged") → list merged MRs around the same time
4. gitlab_get_merge_request(project, mrIid=...)    → read review discussion/notes for context
5. gitlab_get_mr_diff(project, mrIid=...)          → see the actual code change
6. gitlab_get_file(project, filePath=...)          → read the affected source file
```

### 2. Understanding why something was implemented a certain way

```
1. gitlab_get_file              → read the current source code
2. gitlab_get_commits           → find who changed this file and when
3. gitlab_get_merge_request     → read the MR description and review notes for rationale
```

### 3. Finding which MR introduced a change

```
1. gitlab_get_commits(project, ref="main", query="feature-x") → narrow down the range
2. gitlab_get_merge_requests(project, state="merged")         → list candidates
3. gitlab_get_mr_changes(project, mrIid=...)                  → check which files were touched
4. gitlab_get_mr_diff(project, mrIid=...)                      → inspect the actual diff
```

---

## Tool reference

### `gitlab_list_projects`
- Optional `search`, `limit`. Call this when the project ID/path is unknown.
- Returns: id, path_with_namespace, name, description, default_branch, web_url.
- This is the **single discovery tool** — GitLab has no separate project/repo split.

### `gitlab_get_commits`
- **Best first tool** — lightweight, gives commit messages and authors fast.
- Requires `project`. Use `query` to filter by Jira ticket key (e.g. `"PROJ-123"`).
- Use `ref` to scope to a specific branch, tag, or commit.
- Returns: commit SHAs, messages, authors, timestamps.

### `gitlab_get_merge_requests`
- Lists MRs for a project. Default `state` is `opened`; use `merged` for
  history, `closed` for abandoned work, or `all` to see everything.
- Returns: iid, title, state, author, source/target branches, labels, description snippet.

### `gitlab_get_merge_request`
- Fetches a single MR by `mrIid`, **including all review comments/notes**.
- Use after `gitlab_get_merge_requests` to deep-dive into the most relevant one.
- Returns: full description, source/target branch, approval status, discussion thread.

### `gitlab_get_mr_changes`
- Lists the files changed in an MR — ADD / MODIFY / DELETE / RENAME per file.
- Use this for a quick overview before pulling the full diff.

### `gitlab_get_mr_diff`
- Fetches the full unified diff for an MR.
- Use when you need the actual line-by-line code change, not just file names.

### `gitlab_get_file`
- Fetches full file contents at a branch/tag/commit ref.
- Use `ref` to pin to the exact commit from a related commit SHA if you need
  historical context.

---

## Key parameters

| Parameter | Description                                                  | Example                  |
|-----------|----------------------------------------------------------------|---------------------------|
| project   | Numeric project ID or URL-encoded `namespace/path` — use `gitlab_list_projects` if unknown | `42`, `team/payment-service` |
| ref       | Branch, tag, or commit SHA                                   | `main`, `release/2.4`, `abc1234` |
| query     | String to match in commit messages                            | `PROJ-456`                |
| state     | MR state filter for `gitlab_get_merge_requests`               | `opened`, `merged`, `closed`, `all` |
| mrIid     | Merge request **internal ID** (scoped to the project, not global) | `17`                  |
| filePath  | Path from repo root, no leading slash                          | `src/App.java`            |

---

## Tips

- **Always search commits with the Jira key first** — it's the fastest way to
  link a ticket to a code change.
- MR IDs are **iid** (per-project), not a global MR ID — don't confuse it
  with IDs from other projects or with commit SHAs.
- If `gitlab_get_commits` returns nothing for a ticket key, try a keyword from
  the ticket title instead.
- MR review notes/comments often contain the *rationale* for implementation
  choices that aren't in the commit message — always check them for "why" questions.
- Use `gitlab_get_mr_changes` before `gitlab_get_mr_diff` when you only need
  to know *which* files changed, to avoid pulling a large diff unnecessarily.
- `gitlab_get_file` on a config file (e.g. `pom.xml`, `build.gradle`,
  `Dockerfile`) is useful for understanding dependencies and build setup.


---

## Issues, CI, and the write surface

Beyond code context, the server exposes GitLab issues and pipelines:

```
gitlab_list_issues(project, labels=[...], state="opened")  → filter the backlog
gitlab_get_issue(project, issueIid)                        → one issue, full text
gitlab_get_issue_notes(project, issueIid)                  → its comments (+ note ids)
gitlab_get_pipelines(project, ref="my-branch")             → is that branch green?
```

`issueIid` is the `#N` shown in the UI — the per-project internal id, **not** the
global `id` field. Passing the wrong one 404s.

`gitlab_list_issues` **ANDs** its `labels` filter: every label listed must be
present. GitLab has no OR, so to match any-of, fetch broadly and filter yourself.

### Writes are off by default

Creating and editing things needs `GITLAB_ALLOW_WRITE=1` in `.env`, and may be
narrowed further to specific projects with `GITLAB_WRITE_PROJECTS`. When the
switch is off the write tools are not offered at all — if you do not see them,
they are disabled, which is a deployment decision and not a problem to solve.

```
gitlab_create_merge_request(project, sourceBranch, targetBranch, title, description)
gitlab_update_merge_request(project, mrIid, title?, description?)
gitlab_create_mr_note(project, mrIid, body)
gitlab_create_issue(project, title, description?, labels?)
gitlab_create_issue_note(project, issueIid, body)
gitlab_update_issue_note(project, issueIid, noteId, body)
```

**If a write is refused, report it and stop.** Do not fall back to `curl`, to
`glab`, or to a different project. The refusal is the configuration working.

### Keeping a progress log to one comment

Post once, then edit that note — do not append a new comment per update. A
reviewer opening the issue should find one current summary, not twenty stale
ones.

```
1. gitlab_get_issue_notes(project, issueIid)
   → look for your own marker heading, e.g. "## Workpad"
2. found?  gitlab_update_issue_note(project, issueIid, noteId, body)
   not found? gitlab_create_issue_note(project, issueIid, body)
```

`update_issue_note` **replaces** the body outright, so build the whole new text
before you call it.

### Opening a merge request

Put `Closes #N` in the description. That is what links the MR to its issue, and
that link is what a human reviews.

Opening the MR is where your work ends. Merging is a human decision, and the
token you are given cannot do it — a 403 on merge is expected, not a puzzle.

### What you cannot do, by design

There is no tool to set an issue's labels, close or reopen an issue, or merge an
MR. In the symphony workflow an issue's `symphony::` label **is** its workflow
state and the orchestrator owns every transition. `gitlab_create_issue` refuses
labels in that namespace, so a follow-up you file arrives unlabelled and a human
decides whether it enters the queue. Do not try to work around this.
