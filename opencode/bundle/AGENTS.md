# House rules

Workplace defaults. These load globally and are *additive* to any
project- or user-level `AGENTS.md` — they do not replace them.

## Prefer skills over raw tools

When a skill exists for a task, use it instead of calling the underlying
tools directly. In particular, all access to Jira, Bitbucket, GitLab,
JFrog, Confluence, and M-Files MUST go through the corresponding skill
(`jira-fetch`, `bitbucket-fetch`, `gitlab-fetch`, `jfrog-fetch`,
`confluence-fetch`, `mfiles-fetch`) — do not call the `jira_*`,
`bitbucket_*`, `gitlab_*`, `jfrog_*`, `confluence_*`, or `mfiles_*` MCP
tools directly. The skills carry the conventions and guardrails for those
services.

## Git conventions

Follow `branch-naming` and `commit-conventions` for any git work.
