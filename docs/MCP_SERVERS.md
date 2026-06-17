# MCP servers (Bitbucket & Jira)

The image ships two first-party, **read-only** MCP servers that let the agent
query the internal Bitbucket and Jira instances directly — both already on the
Squid allowlist. They are `type: local` stdio servers (`node`), with their
runtime deps vendored at build time so nothing hits npm at container start.

- **Bitbucket** (`opencode/mcp-servers/bitbucket/`): `list_projects`,
  `list_repos`, `get_commits`, `get_pull_requests`, `get_pull_request`,
  `get_pr_changes`, `get_pr_diff`, `get_file`.
- **Jira** (`opencode/mcp-servers/jira/`): `get_issue`, `search` (JQL),
  `get_current_user`.

Read-only by design — they issue GETs only and never write, mirroring the
`git:ro`-by-default posture. There is no push/comment capability.

## Enabling them

There is **no separate on/off switch**: a server is enabled exactly when its
credentials are present in `.env` (and not force-disabled). The two planes are
independent — you can have API access without git, or vice versa.

| Service   | Enabled when these are set                          | Force off               |
|-----------|-----------------------------------------------------|-------------------------|
| Bitbucket | `BITBUCKET_BASE_URL`, `BITBUCKET_USER`, `BITBUCKET_PAT` | `DISABLE_BITBUCKET_MCP=1` |
| Jira      | `JIRA_BASE_URL`, `JIRA_USER`, `JIRA_PAT`            | `DISABLE_JIRA_MCP=1`    |

Credential presence is the gate because the servers **exit on boot** without
their env; registering one with no creds would just produce a noisy failed
attach. When creds are absent the entrypoint omits the block entirely.

## How auth is wired (no passwords, no hand-encoding)

A single Bitbucket **PAT** authenticates both `git` and the REST API (verified:
the PAT works as HTTP Basic against Bitbucket's REST API), so no account
password is stored anywhere.

Each server reads the **canonical `.env` names directly** —
`BITBUCKET_BASE_URL`/`BITBUCKET_USER`/`BITBUCKET_PAT` and the `JIRA_*`
equivalents — and builds its own HTTP Basic header (`base64("<user>:<pat>")`)
at startup. `.env` therefore never contains a pre-encoded blob; you only paste
the PAT.

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

## TLS

Node trusts the corp CA via `NODE_EXTRA_CA_CERTS` (baked as image `ENV` in the
Dockerfile, so it reaches the server whichever process spawns it), so HTTPS MCP
targets validate normally. The servers do **not** disable certificate
verification. If a TLS endpoint fails to connect, the fix is to bake the right
CA into `ca/`, never to skip verification.

## What uses them

- The **`bitbucket-pr-reviewer`** agent fetches PRs directly via the Bitbucket
  tools (`get_pull_request`, `get_pr_changes`, `get_pr_diff`, `get_file`) instead
  of asking for a pasted diff; it falls back to a pasted diff if the MCP is off.
- The **`/sync-jira`** command resolves the issue key from the current branch (or
  an argument) and pulls the ticket into context via `get_issue`.

Both degrade gracefully when their MCP is disabled.

## Adding another service later

Follow the same `<SERVICE>_{BASE_URL,USER,PAT}` shape, drop a server under
`opencode/mcp-servers/<name>/`, allowlist its host under `squid/allowlist.d/`,
and add the credential-gated block to the entrypoint. If a future service needs
a different secret for its API than for git, add an optional `<SERVICE>_API_*`
override rather than reshaping the common case.
