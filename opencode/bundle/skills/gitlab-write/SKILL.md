---
name: gitlab-write
description: "Creates and edits things in GitLab via the GitLab MCP write tools — opening and updating merge requests, commenting on merge requests and issues, keeping a single running workpad comment, and filing follow-up issues. Use when work needs to be published or handed to a human for review, especially in unattended symphony runs. Requires ALLOW_GITLAB_WRITE=1; the skill is absent otherwise."
---

# GitLab MCP — writing

Present only when `ALLOW_GITLAB_WRITE=1`. Reading is the companion
`gitlab-fetch` skill; everything here mutates GitLab.

### Writes are off by default

Creating and editing things needs `ALLOW_GITLAB_WRITE=1` in `.env`, and may be
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
