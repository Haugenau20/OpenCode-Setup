# Architecture

This document describes the design of the workplace OpenCode image. It is the
canonical reference; if the code disagrees with this document, fix one of them.

## Goals

- Ship a single Docker image that gives every developer a consistent,
  locked-down OpenCode environment.
- All traffic out of the container goes through a Squid proxy on a fixed
  allowlist. No incidental internet access.
- Reasonable defaults that work out of the box, with clearly defined extension
  points for per-developer customisation.
- Easy to ship: one image, two tags (`:staging`, `:prod`), distributed via
  Artifactory or built locally.

## Non-goals

- Multi-tenant hosting. One container per developer per repo.
- Running on macOS or Windows hosts. Linux only for now.
- Self-updating. Developers run `docker compose pull` when told to.

## Topology

```
┌── Host (Linux) ────────────────────────────────────────────────────┐
│                                                                    │
│  Frontends (developer picks any/all):                              │
│   • Browser    ─► http://localhost:${OPENCODE_PORT:-4096}          │
│   • Desktop    ─► same URL (installed on host, points at container)│
│   • TUI        ─► ./scripts/opencode (wraps docker exec)           │
│                                                                    │
│  ┌── docker compose project: opencode-${PROJECT_SLUG} ───────────┐ │
│  │                                                               │ │
│  │  net: oc_internal  (internal: true, no gateway)               │ │
│  │  net: oc_proxy     (internal: true)                           │ │
│  │                                                               │ │
│  │  ┌──────────────┐         ┌──────────────┐                    │ │
│  │  │  opencode    │─────────│   squid      │── net: oc_egress ──┼─┼──► allowlist
│  │  │  server      │ oc_proxy│  allowlist   │                    │ │   • LLM API
│  │  │  :4096       │         │  + corp CA   │                    │ │   • Bitbucket
│  │  └──────┬───────┘         └──────────────┘                    │ │   • JIRA
│  │         │ oc_internal                                         │ │
│  │         │ (reserved for future MCP/RAG sidecars)              │ │
│  │                                                               │ │
│  │  Volumes:                                                     │ │
│  │   oc_state_${SLUG}    ─► /home/dev/.local/share/opencode      │ │
│  │   oc_cfg_${SLUG}      ─► /home/dev/.config/opencode           │ │
│  │   ${REPO_PATH}        ─► /workspace (bind)                    │ │
│  └───────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### Why these three networks

| Network        | `internal` | Members            | Purpose                              |
|----------------|------------|--------------------|--------------------------------------|
| `oc_internal`  | yes        | opencode (+future) | No egress. Reserved for the RAG MCP server and any other internal-only sidecars we add later. |
| `oc_proxy`     | yes        | opencode, squid    | The only path opencode has to the outside world. |
| `oc_egress`    | no         | squid              | Squid's view of the internet.        |

Because `oc_internal` and `oc_proxy` are both `internal: true`, opencode has
no default route to the internet. The only way out is to make an HTTP request
that resolves via the proxy env vars and goes through Squid.

## One image, multiple frontends

OpenCode has a client/server architecture: a single backend serves the TUI,
the web UI, and the desktop app simultaneously over HTTP + SSE. We ship one
image that runs `opencode serve` and publish the port to localhost. The
developer chooses which frontend to use; they all share the same session and
state.

The desktop app is installed by the developer on their own host (it is an
Electron app). It connects to `http://localhost:${OPENCODE_PORT}` exactly
like the browser does.

## Image layout

```
/opt/opencode/bundle/                # workplace-shipped agents/skills/etc.
  agents/  skills/  commands/  mcp/  # read-only inside the image
/etc/opencode/policy.yaml            # read-only workplace policy
/usr/local/share/ca-certificates/    # corp CA baked in here
/usr/local/bin/git                   # symlink to git-guard (PATH-first)
/usr/local/bin/git-guard             # wraps real git, blocks remote ops
/usr/bin/git                         # actual git binary
/home/dev/                           # non-root user, UID/GID remapped at start
```

### Config layering

OpenCode reads from `~/.config/opencode/`. We layer four sources, merged at
container start by `entrypoint.sh`:

1. **Bundle** (`/opt/opencode/bundle/`) — workplace agents/skills/etc.
   shipped in the image. Read-only.
2. **Policy** (`/etc/opencode/policy.yaml`) — workplace defaults that
   developers must not override (telemetry off, autoupdate off, etc.).
3. **User layer** (`oc_cfg_${SLUG}` volume mounted at `~/.config/opencode/`).
   Owned by the developer. The entrypoint symlinks each bundle item into this
   directory unless the user has shadowed it or listed it in `disabled.yaml`.
4. **Project** (`<repo>/.opencode/`) — repo-local config, the standard
   OpenCode location.

To disable a bundled item, the developer either creates a file with the same
name in their user layer (the symlink is skipped if the file exists) or
edits `~/.config/opencode/disabled.yaml`:

```yaml
disabled:
  agents:  [code-reviewer]
  skills:  [security-review]
  commands: []
  mcp:     []
```

## Git safety

By default `ALLOW_REMOTE_GIT=0` in `.env`. A shim at `/usr/local/bin/git`
intercepts `push`, `fetch`, `pull`, `clone`, and `remote` and refuses unless
the env var is `1`. Local commits, status, diff, log, etc. work normally.

Bitbucket authentication for git uses a credential helper that reads
`BITBUCKET_USER` and `BITBUCKET_PAT` from the environment. The PAT never
touches disk inside the container.

When the developer flips the switch, the shell prompt changes from
`[oc:myrepo|git:ro]` to `[oc:myrepo|git:rw]` so the state is always visible.

## Secrets

Everything sensitive lives in `.env` on the host, mounted via Compose's
`env_file`. The container itself never has secrets baked in. `.env` is
gitignored; `.env.example` is the source of truth for the schema.

## Telemetry

We block phone-home in two layers:

1. **Configuration:** `policy.yaml` sets `OPENCODE_DISABLE_TELEMETRY=1`,
   `DO_NOT_TRACK=1`, `npm_config_audit=false`, `NEXT_TELEMETRY_DISABLED=1`,
   etc.
2. **Network:** Squid only allows the LLM, Bitbucket, and JIRA endpoints.
   Anything else is dropped.

We do not maintain an exhaustive list of telemetry endpoints. Squid's
allowlist is the backstop.

## State and persistence

Per-project named volumes survive container restarts:

- `oc_state_${PROJECT_SLUG}` — sessions, conversation logs.
- `oc_cfg_${PROJECT_SLUG}` — user-layer agents/skills/commands.

Setting `ENABLE_SESSION_LOGS=0` swaps the state volume for a tmpfs so nothing
is persisted to disk.

## Running multiple stacks in parallel

Two repos open at once = two clones of this scaffold with different
`PROJECT_SLUG` and `OPENCODE_PORT` values in `.env`. Compose project names,
volume names, and the published port are all derived from `PROJECT_SLUG`, so
nothing collides.

## Bitbucket PAT and git

`BITBUCKET_USER` and `BITBUCKET_PAT` come from `.env`. The entrypoint installs
a git credential helper that emits them on demand. Devs can clone HTTPS Bitbucket
URLs and (once `ALLOW_REMOTE_GIT=1`) push to them without storing the PAT on
disk.

## Future work

- **RAG MCP server.** Will join `oc_internal` as a third compose service.
  OpenCode will talk to it as `http://rag:PORT` — no Squid hop.
- **TeamCity CI.** Build on push to `main`, publish `:staging`; manual
  promotion to `:prod`.
- **`/report-bug` slash command.** Sketched but unimplemented: bundle the
  last N session messages and sanitised env, POST to a JIRA project via the
  already-allowlisted JIRA API.
- **Desktop-app SSH connect.** Upstream feature request; not relevant while
  the container runs on the same host.
