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
│            │                                                       │
│            │ localhost:4096 (published by oc-publish)              │
│            ▼                                                       │
│  ┌── docker compose project: opencode-${PROJECT_SLUG} ───────────┐ │
│  │                                                               │ │
│  │  net: oc_internal  (internal: true, no gateway)               │ │
│  │  net: oc_proxy     (internal: true)                           │ │
│  │  net: oc_publish   (non-internal, host-facing)                │ │
│  │                                                               │ │
│  │  ┌──────────────┐  oc_proxy  ┌──────────────┐                │ │
│  │  │  opencode    │────────────│   squid      │─ oc_egress ────┼─┼──► allowlist
│  │  │  server      │            │  allowlist   │                │ │   • LLM API
│  │  │  :4096       │            │  + corp CA   │                │ │   • Bitbucket
│  │  └──────┬───────┘            └──────────────┘                │ │   • JIRA
│  │         │ oc_internal                                        │ │
│  │         │ (reserved for future MCP/RAG sidecars)             │ │
│  │                                                              │ │
│  │  ┌──────────────┐  oc_proxy                                  │ │
│  │  │  oc-publish  │◄──── TCP:opencode:4096                     │ │
│  │  │  socat fwd   │  oc_publish (non-internal)                 │ │
│  │  │  :4096 pub.  │◄──────────────────── host :4096            │ │
│  │  └──────────────┘                                            │ │
│  │                                                               │ │
│  │  Volumes:                                                     │ │
│  │   oc_state_${SLUG}    ─► /home/dev/.local/share/opencode      │ │
│  │   oc_cfg_${SLUG}      ─► /home/dev/.config/opencode           │ │
│  │   ${REPO_PATH}        ─► /workspace (bind)                    │ │
│  └───────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### Why these four networks

| Network        | `internal` | Members              | Purpose                              |
|----------------|------------|----------------------|--------------------------------------|
| `oc_internal`  | yes        | opencode (+future)   | No egress. Reserved for the RAG MCP server and any other internal-only sidecars we add later. |
| `oc_proxy`     | yes        | opencode, squid, oc-publish | The only path opencode has to the outside world. |
| `oc_egress`    | no         | squid                | Squid's view of the internet.        |
| `oc_publish`   | no         | oc-publish           | Lets the publisher sidecar expose opencode's port to the host without giving opencode egress. |

Because `oc_internal` and `oc_proxy` are both `internal: true`, opencode has
no default route to the internet. The only way out is to make an HTTP request
that resolves via the proxy env vars and goes through Squid.

## One image, multiple frontends

OpenCode has a client/server architecture: a single backend serves the TUI,
the web UI, and the desktop app simultaneously over HTTP + SSE. We ship one
image that runs `opencode serve`. The developer chooses which frontend to use;
they all share the same session and state.

Because `opencode` is attached only to `internal: true` networks (to prevent
egress), Docker Engine 28+ refuses to bind published host ports for it. The
`oc-publish` sidecar (a minimal `socat` forwarder using the squid image) sits
on the non-internal `oc_publish` bridge and forwards
`localhost:4096 -> opencode:4096` over `oc_proxy`. This gives the host a
reachable port without granting opencode any network egress.

The desktop app is installed by the developer on their own host (it is an
Electron app). It connects to `http://localhost:${OPENCODE_PORT}` exactly
like the browser does.

## Image layout

```
/opt/opencode/bundle/                # workplace-shipped agents/skills/etc.
  agents/  skills/  commands/  mcp/  # read-only inside the image
  plugins/<name>/                    # opt-in plugins, built+vendored at build time
/etc/opencode/policy.yaml            # read-only workplace policy
/etc/opencode/disabled.yaml.default  # seed for the user's toggle file
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

`disabled.yaml` is seeded on first boot from
`/etc/opencode/disabled.yaml.default` (the entrypoint copies it only if absent),
so the developer always has a self-documenting menu to edit.

## Plugins

Plugins (`bundle/plugins/<name>/`) are handled differently from the other
bundle kinds in two ways:

1. **Built, not checked in.** The plugin code — frequently with a
   `node_modules/` — is cloned at a pinned ref and vendored by the
   `plugins-build` stage of the Dockerfile, then copied into the image. The repo
   stores only the build recipe, not the vendored code.
2. **Opt-in (default OFF).** Agents/skills/commands ship enabled and are turned
   *off* via the `disabled:` lists. Plugins ship disabled and are turned *on*
   either by the `ENABLED_PLUGINS` env var (set in `.env` — the easy path) or by
   listing `<name>` under `plugins: { enabled: [...] }` in `disabled.yaml`; the
   entrypoint unions the two. The `/plugins` command shows live state.

**Load mechanism.** OpenCode auto-scans `plugin/*.{ts,js}` in each config dir and
imports the matching files directly, following symlinks
(`Bun.Glob("{plugin,plugins}/*.{ts,js}", {symlink:true})` — verified in the
1.16.2 and 1.17.3 binaries). The entrypoint symlinks the entry files of
*enabled* plugins (read from
each plugin's `entries` manifest) into `~/.config/opencode/plugin/`. Node/Bun
resolves imports from the entry's real path, so a plugin's vendored
`node_modules/` is found without any install.

We deliberately avoid the `plugin` array in `opencode.json`: that path triggers
a Bun network install at startup, which the egress lock blocks. `policy.yaml`
additionally sets `BUN_CONFIG_SKIP_INSTALL_PACKAGES=true` so no startup install
is ever attempted. Full flow in [`ADDING_PLUGINS.md`](ADDING_PLUGINS.md).

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

## Verified upstream facts

Checked 2026-05-11 against opencode-ai 1.14.48 (`npm view opencode-ai`).

- **Package name.** `opencode-ai` on the public npm registry. `dist-tags.latest`
  is `1.14.48`. The Dockerfile pins via the `OPENCODE_VERSION` build arg.
- **CLI surface.** `opencode serve` exists and accepts `--hostname` (default
  `127.0.0.1`) and `--port` (default `0` = ephemeral). Confirmed by running
  `opencode serve --help` against the published binary. `opencode web` is a
  sibling subcommand that also opens a browser; we use `serve` because the
  container is headless and the user opens the URL on the host.
- **Provider schema.** `@ai-sdk/openai-compatible` provider takes
  `options.baseURL` and `options.apiKey` (plus optional `options.headers`).
  Matches what `opencode.json.tmpl` renders. Reference:
  https://opencode.ai/docs/providers/ and https://opencode.ai/docs/config/
  (both pages 403 to unauthenticated fetchers but are reachable from a
  browser).
