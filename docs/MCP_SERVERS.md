# MCP servers (Bitbucket, GitLab, Jira, JFrog & Confluence)

The image ships five first-party, **read-only** MCP servers that let the agent
query the internal Bitbucket, GitLab, Jira, JFrog Artifactory, and Confluence
instances directly — all already on the Squid allowlist. They are `type: local`
stdio servers (`node`), with their runtime deps vendored at build time so nothing
hits npm at container start.

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
- **JFrog** (`opencode/mcp-servers/jfrog/`): `list_repositories`,
  `get_repository`, `search_artifacts`, `gavc_search`, `latest_version`,
  `get_item_info`, `get_file`, `list_builds`, `get_build`, `aql_search`.
  Artifacts are addressed by a **repository key** + path; Maven artifacts also by
  **GAVC** coordinates. This is the *published-artifact* plane — for source code
  use GitLab/Bitbucket.
- **Confluence** (`opencode/mcp-servers/confluence/`): `get_page` (by id, or by
  space+title), `search` (CQL), `get_page_children`, `list_spaces`,
  `get_current_user`. This is the *documentation/wiki* plane — pages live in a
  **space** (by space key) and form a tree of numeric **content ids**. For
  issues use Jira; for source use GitLab/Bitbucket.

Read-only by design — there is no push/comment/deploy capability, mirroring the
`git:ro`-by-default posture. Every tool issues GETs **except** JFrog's
`aql_search`, which uses POST — but only because an AQL query rides in the
request **body** (like an Elasticsearch `_search`), not because it writes. AQL's
sole operation is `find`; the language cannot express a mutation, so the posture
is still strictly read-only. To keep an unbounded query from scanning a large
(1M+ item) instance, `aql_search` enforces a `.limit()` and caps returned rows.

Bitbucket and GitLab additionally double as **git remotes** over HTTPS (clone/push);
see [`docs/ALLOWING_GIT_PUSH.md`](ALLOWING_GIT_PUSH.md). Jira, JFrog and Confluence
have no git transport — they are API-only.

## Enabling them

There is **no separate on/off switch**: a server is enabled exactly when its
credentials are present in `.env` (and not force-disabled). The two planes are
independent — you can have API access without git, or vice versa.

| Service   | Enabled when these are set                          | Force off               |
|-----------|-----------------------------------------------------|-------------------------|
| Bitbucket | `BITBUCKET_BASE_URL`, `BITBUCKET_PAT` (`BITBUCKET_USER` optional, git-over-HTTPS only) | `DISABLE_BITBUCKET_MCP=1` |
| GitLab    | `GITLAB_BASE_URL`, `GITLAB_USER`, `GITLAB_PAT`       | `DISABLE_GITLAB_MCP=1`  |
| Jira      | `JIRA_BASE_URL`, `JIRA_PAT`                         | `DISABLE_JIRA_MCP=1`    |
| JFrog     | `JFROG_BASE_URL`, `JFROG_PAT`                       | `DISABLE_JFROG_MCP=1`   |
| Confluence| `CONFLUENCE_BASE_URL`, `CONFLUENCE_PAT`            | `DISABLE_CONFLUENCE_MCP=1` |

Credential presence is the gate because the servers **exit on boot** without
their env; registering one with no creds would just produce a noisy failed
attach. When creds are absent the entrypoint omits the block entirely.

## How auth is wired (no passwords, no hand-encoding)

No account passwords are stored — each service authenticates with a PAT, in
the scheme its server expects (verified against the live instances):

- **Bitbucket** (Data Center) — the REST API presents the PAT as a **Bearer**
  token (`Authorization: Bearer <BITBUCKET_PAT>`); no username is involved, same
  shape as Jira. The same PAT still serves `git`, but git-over-HTTPS speaks HTTP
  Basic (`BITBUCKET_USER:BITBUCKET_PAT`) — handled by the entrypoint's credential
  helper, not this server — so `BITBUCKET_USER` is optional and only needed if
  you clone/push Bitbucket over HTTPS.
- **GitLab** — a single PAT serves both `git` and the REST API too, but the
  REST API uses GitLab's own idiomatic scheme: the PAT goes as a
  `PRIVATE-TOKEN: <GITLAB_PAT>` header against `${GITLAB_BASE_URL}/api/v4`
  (not Basic, not Bearer). Git transport still authenticates as HTTP Basic
  (`GITLAB_USER:GITLAB_PAT`), same shape as Bitbucket.
- **Jira** (Data Center) — the PAT is presented as a **Bearer** token
  (`Authorization: Bearer <JIRA_PAT>`); no username is involved.
- **JFrog** (Artifactory) — the access token is presented as a **Bearer** token
  too (`Authorization: Bearer <JFROG_PAT>`); no username is involved. Same shape
  as Jira because JFrog is likewise API-only (no git plane). The server appends
  `/artifactory/api` to `JFROG_BASE_URL`.
- **Confluence** (Data Center) — the PAT is presented as a **Bearer** token
  (`Authorization: Bearer <CONFLUENCE_PAT>`); no username is involved, same shape
  as Jira. The server appends `/rest/api` to `CONFLUENCE_BASE_URL`.

Each server reads the **canonical `.env` names directly** (`BITBUCKET_*`,
`GITLAB_*`, `JIRA_*`, `JFROG_*`, `CONFLUENCE_*`) and builds its own auth header at
startup. `.env` therefore never contains a pre-encoded blob; you only paste the PAT.

This matters for *where the values live*. Compose loads `.env` via `env_file`,
so those vars are part of the **container's stored environment** and are
inherited by any process that spawns the server — both the backend and the
TUI's `docker exec`. (A value merely `export`-ed at runtime by the entrypoint
would live only in PID 1 and be missing if the TUI launches the server, which
is exactly what produced an early `-32000: Connection closed`.)

The entrypoint's only job for MCP is gating: it `jq`-injects the matching
`mcp.<name>` block into the rendered `~/.config/opencode/opencode.json` only
when a service's credential trio is present. All egress goes through Squid.

> **`BITBUCKET_BASE_URL` — prefer the canonical HTTPS endpoint** your server
> redirects to (e.g. `https://bitbucket.internal.example:8443`). The plain-HTTP
> connector (`http://…:7990`) also serves the REST API, but a repo cloned from it
> can trigger an auth-redirect prompt (see TROUBLESHOOTING and
> `BITBUCKET_LEGACY_URL`). `https://` only works on the real TLS port — pointing
> it at the plain-HTTP connector port yields a TLS `wrong version number` error.
> No trailing slash.
>
> **`GITLAB_BASE_URL` is HTTPS**, unlike Bitbucket above — no trailing slash
> either way.
>
> **`JFROG_BASE_URL` is HTTPS** and is the JFrog *platform* base — the server
> appends `/artifactory/api` itself, so set it to e.g.
> `https://jfrog.internal.example` (no `/artifactory`, no trailing slash). If
> your image registry (`IMAGE_REGISTRY`) is the same host, one allowlist entry
> covers both.
>
> **`CONFLUENCE_BASE_URL` is the site base** — the server appends `/rest/api`
> itself. Confluence's default connector is **HTTP on port 8090**, so include the
> port: `http://confluence.internal.example:8090` (no trailing slash). That port
> must be in **both** `Safe_ports` and `SSL_ports` in `squid.conf` — see the
> CONNECT note below for why even a plain-HTTP target needs `SSL_ports`.

## Proxy ports: every MCP target port must be in `SSL_ports`

This is the non-obvious one, and it has burned at least one afternoon of
debugging. The MCP servers' HTTP client (undici `ProxyAgent`) reaches squid via
an **HTTP `CONNECT` tunnel for every request — including plain `http://`
targets** — not a normal proxied `GET`. squid only permits `CONNECT` to ports in
`SSL_ports` (`http_access deny CONNECT !SSL_ports`). So:

- A service's port must be in **`SSL_ports`**, not just `Safe_ports`, or its MCP
  calls fail with a **denied `CONNECT` (403)**.
- This is true even for plaintext HTTP. JFrog/Bitbucket on `http://…:80` need
  **`80` in `SSL_ports`** (it's there now); Confluence on `:8090` needs `8090`
  there; an HTTPS service on `:443` is already covered.

The confusing part: a plain `curl` through the proxy to the *same* URL **works**,
because curl issues a normal proxied `GET` (allowed via `Safe_ports`). So "curl
works but the MCP gets a DNS/SERVFAIL/403 error" is the signature of a port
that's in `Safe_ports` but missing from `SSL_ports`. To reproduce what the MCP
actually does, force a tunnel: `curl --proxytunnel --proxy http://squid:3128
http://<host>:<port>/…` — if that returns `403` while the plain proxied curl
returns `200`, add `<port>` to `SSL_ports`.

> Related gotcha — **keep corp domain suffixes OUT of `NO_PROXY`.** `NO_PROXY`
> (in `docker-compose.yml` and `policy.yaml`) lists only loopback + the docker
> sidecar names; it deliberately does **not** include `.local`. If it did, any
> internal service addressed by a `*.local` **FQDN** — e.g.
> `bitbucket.corp.local` — would match `NO_PROXY` and be routed **directly**
> instead of through squid. The container has no direct egress, so `git` and
> `curl` to that host fail (`could not resolve host` / `CONNECT tunnel failed`).
> This is not just a manual-testing quirk: it breaks `git`-over-HTTPS (the
> `ALLOW_REMOTE_GIT` feature) too. The MCP would still work — undici's
> `ProxyAgent` ignores `NO_PROXY` — which is exactly what masks the problem: the
> REST plane looks healthy while git is broken. To mirror the MCP when testing by
> hand, force the proxy: `env no_proxy= NO_PROXY= curl -x http://squid:3128 …`.

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
- The **`jfrog-fetch`** skill drives the JFrog tools for artifact/dependency
  and build lookups — resolving the latest version of a library, finding where
  an artifact lives (`search_artifacts` / `gavc_search`), browsing a repo tree
  (`get_item_info`), reading a published `.pom`/manifest (`get_file`), inspecting
  CI build-info (`list_builds` / `get_build`), or running complex multi-criteria
  queries via `aql_search` for anything the simpler tools can't express.
- The **`confluence-fetch`** skill drives the Confluence tools for
  documentation/wiki lookups — reading a page (`get_page` by id or space+title),
  searching the wiki with CQL (`search`), browsing a space's page tree
  (`get_page_children`), or discovering spaces (`list_spaces`). A common
  cross-reference is **Jira → Confluence**: from a ticket to its linked spec or
  runbook page.

All five degrade gracefully when their MCP is disabled.

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

**JFrog** shows the *API-only* variant of the recipe (like Jira, no git plane):
a two-value `JFROG_{BASE_URL,PAT}` pair (no `_USER`), Bearer auth, its own
`squid/allowlist.d/40-jfrog.conf`, a credential-gated block in the entrypoint
that does **not** touch the git-credential helper, and a `jfrog-fetch` skill. The
Dockerfile needed no change — its `mcp-build` stage globs every directory under
`opencode/mcp-servers/*`, so a new server folder is vendored automatically.

**Confluence** is the most recent worked example, and adds the one wrinkle the
others didn't hit: a **non-standard port**. It's the same API-only,
Bearer-auth, two-value `CONFLUENCE_{BASE_URL,PAT}` shape as Jira/JFrog, with its
own `squid/allowlist.d/50-confluence.conf` and a `confluence-fetch` skill — but
because Confluence's default connector is HTTP on **8090**, that port had to be
opened in `squid.conf` (`Safe_ports`, plus `SSL_ports` to cover a TLS-fronted
instance). The allowlist `.conf` files take **hostnames only**; ports always go
in `squid.conf`, exactly as Bitbucket's git port `7990` does.
