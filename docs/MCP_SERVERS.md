# MCP servers (Bitbucket, GitLab & Jira)

The image ships three first-party, **read-only** MCP servers that let the agent
query the internal Bitbucket, GitLab, and Jira instances directly — all already
on the Squid allowlist. They are `type: local` stdio servers (`node`), with
their runtime deps vendored at build time so nothing hits npm at container start.

- **Bitbucket** (`opencode/mcp-servers/bitbucket/`): `list_projects`,
  `list_repos`, `get_commits`, `get_pull_requests`, `get_pull_request`,
  `get_pr_changes`, `get_pr_diff`, `get_file`.
- **GitLab** (`opencode/mcp-servers/gitlab/`): `list_projects`, `get_commits`,
  `get_merge_requests`, `get_merge_request` (incl. review notes), `get_mr_changes`,
  `get_mr_diff`, `get_file`. In GitLab a *project* is the repo itself — no
  separate project/repo split like Bitbucket — identified by numeric id or
  URL-encoded `namespace/path`. Pull requests are called **merge requests**.
- **Jira** (`opencode/mcp-servers/jira/`): `get_issue`, `search` (JQL),
  `get_current_user`.

Read-only by design — they issue GETs only and never write, mirroring the
`git:ro`-by-default posture. There is no push/comment capability.

Bitbucket and GitLab additionally double as **git remotes** over HTTPS (clone/push);
see [`docs/ALLOWING_GIT_PUSH.md`](ALLOWING_GIT_PUSH.md). Jira has no git transport.

## Enabling them

There is **no separate on/off switch**: a server is enabled exactly when its
credentials are present in `.env` (and not force-disabled). The two planes are
independent — you can have API access without git, or vice versa.

| Service   | Enabled when these are set                          | Force off               |
|-----------|-----------------------------------------------------|-------------------------|
| Bitbucket | `BITBUCKET_BASE_URL`, `BITBUCKET_USER`, `BITBUCKET_PAT` | `DISABLE_BITBUCKET_MCP=1` |
| GitLab    | `GITLAB_BASE_URL`, `GITLAB_USER`, `GITLAB_PAT`       | `DISABLE_GITLAB_MCP=1`  |
| Jira      | `JIRA_BASE_URL`, `JIRA_PAT`                         | `DISABLE_JIRA_MCP=1`    |

Credential presence is the gate because the servers **exit on boot** without
their env; registering one with no creds would just produce a noisy failed
attach. When creds are absent the entrypoint omits the block entirely.

## How auth is wired (no passwords, no hand-encoding)

No account passwords are stored — each service authenticates with a PAT, in
the scheme its server expects (verified against the live instances):

- **Bitbucket** — a single PAT serves both `git` and the REST API, presented as
  HTTP Basic. The server builds `base64("<BITBUCKET_USER>:<BITBUCKET_PAT>")`.
- **GitLab** — a single PAT serves both `git` and the REST API too, but the
  REST API uses GitLab's own idiomatic scheme: the PAT goes as a
  `PRIVATE-TOKEN: <GITLAB_PAT>` header against `${GITLAB_BASE_URL}/api/v4`
  (not Basic, not Bearer). Git transport still authenticates as HTTP Basic
  (`GITLAB_USER:GITLAB_PAT`), same shape as Bitbucket.
- **Jira** (Data Center) — the PAT is presented as a **Bearer** token
  (`Authorization: Bearer <JIRA_PAT>`); no username is involved.

Each server reads the **canonical `.env` names directly** (`BITBUCKET_*`,
`GITLAB_*`, `JIRA_*`) and builds its own auth header at startup. `.env`
therefore never contains a pre-encoded blob; you only paste the PAT.

This matters for *where the values live*. Compose loads `.env` via `env_file`,
so those vars are part of the **container's stored environment** and are
inherited by any process that spawns the server — both the backend and the
TUI's `docker exec`. (A value merely `export`-ed at runtime by the entrypoint
would live only in PID 1 and be missing if the TUI launches the server, which
is exactly what produced an early `-32000: Connection closed`.)

The entrypoint's only job for MCP is gating: it `jq`-injects the matching
`mcp.<name>` block into the rendered `~/.config/opencode/opencode.json` only
when a service's credential trio is present. All egress goes through Squid.

> **`BITBUCKET_BASE_URL` is plain HTTP on the internal instance.** Using
> `https://` yields a TLS `wrong version number` error. Set the scheme your
> instance actually serves; no trailing slash.
>
> **`GITLAB_BASE_URL` is HTTPS**, unlike Bitbucket above — no trailing slash
> either way.

## TLS

Node trusts the corp CA via `NODE_EXTRA_CA_CERTS` (baked as image `ENV` in the
Dockerfile, so it reaches the server whichever process spawns it), so HTTPS MCP
targets validate normally. GitLab is served over HTTPS and validates against
that same baked corp CA — no code or verification change was needed to add it.
The servers do **not** disable certificate verification. If a TLS endpoint
fails to connect, the fix is to bake the right CA into `ca/`, never to skip
verification.

## What uses them

- The **`bitbucket-pr-reviewer`** agent fetches PRs directly via the Bitbucket
  tools (`get_pull_request`, `get_pr_changes`, `get_pr_diff`, `get_file`) instead
  of asking for a pasted diff; it falls back to a pasted diff if the MCP is off.
- The **`gitlab-fetch`** skill drives the GitLab tools for the analogous
  workflow — most commonly tracing a Jira issue to the merge requests and
  commits that implemented it (`get_commits` filtered by ticket key, then
  `get_merge_requests` / `get_merge_request` / `get_mr_diff`), but also plain
  "what changed in this MR" or "read this file from GitLab" requests.
- The **`/sync-jira`** command resolves the issue key from the current branch (or
  an argument) and pulls the ticket into context via `get_issue`.

All three degrade gracefully when their MCP is disabled.

## Adding another service later

Follow the same `<SERVICE>_{BASE_URL,USER,PAT}` shape, drop a server under
`opencode/mcp-servers/<name>/`, allowlist its host under `squid/allowlist.d/`,
and add the credential-gated block to the entrypoint. If a future service needs
a different secret for its API than for git, add an optional `<SERVICE>_API_*`
override rather than reshaping the common case. GitLab is a recent worked
example of this recipe end to end — same env-var shape, its own
`squid/allowlist.d/30-gitlab.conf`, and a REST auth scheme (`PRIVATE-TOKEN`)
that differs from both Bitbucket and Jira, proving the recipe doesn't assume
one auth style.
