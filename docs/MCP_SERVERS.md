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
password is stored anywhere. At boot the entrypoint:

1. Derives the HTTP Basic credential — `base64("<user>:<pat>")` — and exports it
   as `BB_AUTH` / `JIRA_AUTH`. `.env` therefore never contains a pre-encoded
   blob; you only ever paste the PAT.
2. Exports `BB_BASE_URL` / `JIRA_BASE_URL`.
3. `jq`-injects the matching `mcp.<name>` block into the rendered
   `~/.config/opencode/opencode.json`.

The MCP child processes inherit those vars (and `HTTP(S)_PROXY`) from the
opencode server. All egress goes through Squid.

> **`BITBUCKET_BASE_URL` is plain HTTP on the internal instance.** Using
> `https://` yields a TLS `wrong version number` error. Set the scheme your
> instance actually serves; no trailing slash.

## TLS

Node trusts the corp CA via `NODE_EXTRA_CA_CERTS` (set in `policy.yaml`), so
HTTPS MCP targets validate normally. The servers do **not** disable certificate
verification. If a TLS endpoint fails to connect, the fix is to bake the right
CA into `ca/`, never to skip verification.

## Adding another service later

Follow the same `<SERVICE>_{BASE_URL,USER,PAT}` shape, drop a server under
`opencode/mcp-servers/<name>/`, allowlist its host under `squid/allowlist.d/`,
and add the credential-gated block to the entrypoint. If a future service needs
a different secret for its API than for git, add an optional `<SERVICE>_API_*`
override rather than reshaping the common case.
