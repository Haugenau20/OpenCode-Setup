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

When push is allowed, git authenticates to Bitbucket via a credential helper
that reads `BITBUCKET_USER` and `BITBUCKET_PAT` from the environment. Both
come from `.env`. The PAT is never written to disk inside the container.
