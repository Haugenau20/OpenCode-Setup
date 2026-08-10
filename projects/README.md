# `projects/` — one directory per stack

One checkout of this repo runs any number of stacks. A project is a directory
here; everything that differs between stacks lives in it, and nothing else does.

```
projects/<slug>/
├── .env            # agent env OVERRIDES, layered on the root .env
├── symphony.env    # symphony env OVERRIDES, layered on symphony/.env
├── config/
│   └── WORKFLOW.md # symphony's trusted config — mounted read-only at /config
├── queue/          # file_queue state (todo/, in-progress/, …)
└── workspaces/     # per-item agent workspaces — disposable
```

Create one with:

```
./scripts/new-project.sh <slug> [repo-path]
```

Then use it by naming it:

```
./scripts/opencode -p <slug>
./scripts/symphony -p <slug> check
```

With no `-p` both launchers read the root files only, which is exactly what a
single-project setup did before this directory existed.

## The layering rule

Env files are read in order and the last value wins:

| | agent's container | symphony's container |
|---|---|---|
| shared | `.env` | `symphony/.env` |
| per-project | `projects/<slug>/.env` | `projects/<slug>/symphony.env` |

Put in the root files what every project shares — the LLM endpoint, the image
tag, your git identity. Put in the project files what differs. Mostly that means
**credentials**: a GitLab project access token reaches exactly one project, so
it cannot be shared even in principle.

A project file can also blank an inherited value:

```
CONFLUENCE_PAT=
```

That is not cosmetic. Each MCP server auto-enables on credential presence, so
blanking one keeps that server out of the stack entirely — absent, not disabled.
For a symphony project that is the point: see `docs/SYMPHONY.md` §2.

## What must not go in `config/`

`config/` is bind-mounted into the symphony container. Symphony holds the
Reporter token and nothing else, so the agent's credentials must not be readable
from there — which is why `.env` and `symphony.env` sit a level above it rather
than beside `WORKFLOW.md`. `./scripts/symphony check` refuses to start if an env
file appears inside the mounted config directory.

## Nothing here is committed

`.gitignore` excludes `projects/*`. These directories hold scoped tokens, a
scratch queue and disposable workspaces — all local state.
