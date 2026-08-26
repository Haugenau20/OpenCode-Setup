# Allowing the agent to push, fetch, or pull

By default the container is **read-only with respect to remote git**.
Local commits work. `git push`, `git fetch`, `git pull`, `git clone`, and
`git remote` are blocked.

This applies to anything that runs inside the container, including the agent
and any shell you open with `docker exec`.

## Turning it on

Edit `.env`:

```
ALLOW_REMOTE_GIT=1
```

Apply it:

```
docker compose up -d
```

Your prompt will change from `[oc:myrepo|git:ro]` to `[oc:myrepo|git:rw]`
so the new state is visible.

## Narrowing where it may go

`ALLOW_REMOTE_GIT=1` is binary: once on, every remote is reachable. To restrict
the destination as well, add a whitespace- or comma-separated list of
`host/path` prefixes:

```
ALLOW_REMOTE_GIT=1
GIT_REMOTE_ALLOWLIST=gitlab.internal.example/my-group/
```

Prefixes match on a path-segment boundary, so `…/my-group` admits
`…/my-group/service` but not `…/my-group-evil/service`. Empty or unset means no
restriction beyond the switch itself.

This is defence in depth, not a security boundary — the agent has a shell and
can call `/usr/bin/git` directly, past the shim. It turns a mistake (a stale
branch config, a pasted URL, a hallucinated remote) into a legible local error
instead of a confusing 403. See [`ARCHITECTURE.md`](ARCHITECTURE.md), "The
credential model", for what the actual boundary is.

## Turning it off

Same edit, set back to `0`, `docker compose up -d`. The change takes effect
on the next container restart — already-running shells continue to honour
whatever value was in effect when they started.

## How the block works

`/usr/local/bin/git` is a shell script (`git-guard`) earlier in `PATH` than
the real `git`. It refuses subcommands that touch a remote unless
`ALLOW_REMOTE_GIT=1`. Local subcommands pass through unchanged.

The shim is not a sandbox. A determined user can bypass it. The point is to
prevent the **agent** from doing something irreversible by accident.

## Authentication

When push is allowed, git authenticates via a credential helper that reads the
matching `<SERVICE>_USER` / `<SERVICE>_PAT` pair from the environment — both
come from `.env`, and the PAT is never written to disk inside the container.
The helper is **host-aware**: it picks the credential pair to hand back based
on which remote host git is talking to, so a single container can push to both
Bitbucket and GitLab without juggling credentials yourself.

- **Bitbucket** — `BITBUCKET_USER` / `BITBUCKET_PAT`.
- **GitLab** — `GITLAB_USER` / `GITLAB_PAT`. Same gate (`ALLOW_REMOTE_GIT=1`),
  same credential-helper mechanism, just a different host and a different PAT.
  This is the same PAT the GitLab MCP server uses for the REST API (see
  [`docs/MCP_SERVERS.md`](MCP_SERVERS.md)) — git transport just presents it as
  HTTP Basic (`GITLAB_USER:GITLAB_PAT`) instead of the API's `PRIVATE-TOKEN`
  header.
