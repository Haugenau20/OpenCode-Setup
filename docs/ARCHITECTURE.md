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
- Easy to ship: one image, version-numbered tags (e.g. `0.0.5`), distributed
  via Artifactory or built locally.

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
│  │  │  oc-publish  │◄──── TCP:opencode:4096 & :PTY_WEB_PORT     │ │
│  │  │  2x socat fwd│  oc_publish (non-internal)                 │ │
│  │  │ :4096+:PTY   │◄──────────── host :4096 & :PTY_WEB_PORT    │ │
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
| `oc_publish`   | no         | oc-publish           | Lets the publisher sidecar expose opencode's ports to the host without giving opencode egress. |

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
`localhost:4096 -> opencode:4096` over `oc_proxy` (plus, when the opencode-pty
plugin is enabled, a second listener for its web viewer on the port
`docker-compose.yml` derives from `OPENCODE_PORT` by prepending a `1` — e.g.
`14096` — so it stays clear of the `4096+N` main-port range and is unique per
instance). This gives the host reachable ports without granting opencode any
network egress.

The desktop app is installed by the developer on their own host (it is an
Electron app). It connects to `http://localhost:${OPENCODE_PORT}` exactly
like the browser does.

## Image layout

```
/opt/opencode/bundle/                # workplace-shipped agents/skills/etc.
  AGENTS.md                          # global house rules (symlinked to config dir)
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
   shipped in the image. Read-only. This also includes `AGENTS.md`, the
   global house-rules file, which the entrypoint symlinks to
   `~/.config/opencode/AGENTS.md`. OpenCode loads it globally and concatenates
   it with any project- or user-level `AGENTS.md` (additive, not overriding);
   a developer who drops their own file in the config dir shadows it.
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

### Extra instruction files (`OPENCODE_EXTRA_INSTRUCTIONS`)

`OPENCODE_EXTRA_INSTRUCTIONS` is a generic hook for surfacing context that
lives outside the project root. It is a space/comma-separated list of extra
instruction files (absolute container paths); at boot the entrypoint appends
each to the generated `opencode.json`'s `instructions` array, which OpenCode
loads as global context concatenated with the `AGENTS.md` files. Unset ⇒ a
guaranteed no-op (the entrypoint adds nothing to the config).

The image knows nothing about *why* a path is on that list — it just loads it.
This is deliberate. The motivating case is the launcher's `--also <path>`
flag, which bind-mounts extra host folders at `/workspace-extra/<name>`
(siblings of the repo at `/workspace`). OpenCode runs with `/workspace` as its
project root and its file tools (list/glob/grep/read) are anchored there, so an
open-ended search never looks under `/workspace-extra/` and those mounts are
undiscoverable in practice — the mount is real and readable, but the agent
never finds it.

The fix is split along the right seam. Teaching *this image* about
`/workspace-extra` would couple a general-purpose OpenCode environment to one
launcher's private mount layout. Instead:

- **The launcher owns the whole feature.** It already knows every `--also`
  mount's name, path, and read-only/read-write status at boot, so it generates
  a breadcrumb file naming them, mounts it, and sets
  `OPENCODE_EXTRA_INSTRUCTIONS` to its path. Wording, path convention, and what
  to advertise all live — and are maintained — in the launcher repo.
- **The image contributes one stable primitive**: "load the instruction files
  I'm told to." It never changes as the `--also` feature evolves.

Why the breadcrumb can't just be dropped into a file OpenCode already reads,
with no image hook at all: OpenCode's automatic instruction locations are
`/workspace/AGENTS.md` (the developer's real repo — writing there would show up
in their `git status`) and `~/.config/opencode/AGENTS.md` plus `opencode.json`
(both **owned by this entrypoint** — the AGENTS.md is a symlink to the bundle,
and `opencode.json` is regenerated every boot; a file mounted into that dir also
trips the entrypoint's `chown -R`). So some cooperation from the image is
unavoidable — `OPENCODE_EXTRA_INSTRUCTIONS` keeps it generic instead of
`--also`-specific.

`OPENCODE_EXTRA_INSTRUCTIONS` is intentionally **absent from
`manifest.json` and `.env.example`**, unlike every other env key the container
reads (see [Config layering](#config-layering) and MAINTAINERS.md). It is
internal launcher→image plumbing — injected by the launcher's `--also` compose
overlay, never set by a user — so documenting it would only surface a
never-touched knob in every `.env` and force the launcher's manifest drift check
to demand it in the launcher's `.env.example`. The manifest exists to flag
*user-supplied* keys an older launcher wouldn't know to prompt for; a
launcher-injected var can't drift that way, so it stays off the manifest by
design.

### Extra allowed directories (`OPENCODE_EXTRA_ALLOWED_DIRS`)

`OPENCODE_EXTRA_INSTRUCTIONS` makes the `--also` folders *discoverable*; this is
the other half — it makes them *accessible without a prompt*. OpenCode gates any
tool call that touches a path outside the `/workspace` project root behind its
`external_directory` permission, which defaults to `ask`. So even after the
breadcrumb points the agent at `/workspace-extra/<name>`, the first read/edit
there pops an "Access external directory" confirmation — every session, every
folder.

`OPENCODE_EXTRA_ALLOWED_DIRS` is a space/comma-separated list of path globs; at
boot the entrypoint folds each into the generated `opencode.json`'s
`permission.external_directory` as `allow`. Only the listed globs are allowed;
any other out-of-project path still hits the `ask` default. Unset ⇒ a guaranteed
no-op.

It follows `OPENCODE_EXTRA_INSTRUCTIONS` in every respect: the same generic
image-side primitive ("allow the globs I'm told to"), set by the launcher's
`--also` overlay to the mount root it owns (`/workspace-extra/**`), so the image
never learns the launcher's private mount layout. It is likewise intentionally
**absent from `manifest.json` and `.env.example`** — launcher→image plumbing, not
a user knob — for the same reasons given above.

> Access is allow, not the mount's read/write mode. A `--also` folder mounted
> read-only is still enforced read-only by the kernel; allowing it here only
> suppresses the access prompt for reads. An agent that tries to *write* a
> read-only mount gets a filesystem error rather than a permission prompt, which
> is an acceptable trade for not prompting on every read.

## Plugins

Plugins (`bundle/plugins/<name>/`) are handled differently from the other
bundle kinds in two ways:

1. **Built, not checked in.** The plugin code — frequently with a
   `node_modules/` — is cloned at a pinned ref and vendored by the
   `plugins-build` stage of the Dockerfile, then copied into the image. The repo
   stores only the build recipe, not the vendored code.
2. **Opt-in (default OFF), env-var controlled.** Agents/skills/commands ship
   enabled and are turned *off* via the `disabled:` lists in `disabled.yaml`.
   Plugins are the opposite — opt-in — and their **single source of truth** is
   the `ENABLED_PLUGINS` env var in `.env` (a space/comma list). `disabled.yaml`
   deliberately does *not* control plugins: it persists in a volume and would
   silently override `.env`. Each boot the entrypoint rebuilds the plugin
   symlinks from scratch to match `ENABLED_PLUGINS`. The `/plugins` command shows
   live state.

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

The switch is binary — once on, every remote is reachable.
`GIT_REMOTE_ALLOWLIST` narrows the destination:

```
ALLOW_REMOTE_GIT=1
GIT_REMOTE_ALLOWLIST=gitlab.internal.example/my-group/
```

Whitespace- or comma-separated `host/path` prefixes, matched on a path-segment
boundary, so `…/my-group` is not satisfied by `…/my-group-evil`. It resolves
named remotes through `git remote get-url`, normalizes scp-style
`git@host:path`, ignores ports and userinfo, and honours `-C` / `--git-dir` so
the remote is read from the repo the command will actually act on. An empty
allowlist means "no restriction beyond the switch itself", which is the
behaviour you get if you never set it.

Bitbucket authentication for git uses a credential helper that reads
`BITBUCKET_USER` and `BITBUCKET_PAT` from the environment. The PAT never
touches disk inside the container.

When the developer flips the switch, the shell prompt changes from
`[oc:myrepo|git:ro]` to `[oc:myrepo|git:rw]` so the state is always visible.

Neither the shim nor the allowlist is a security boundary — see
[The credential model](#the-credential-model) below for what actually is.

## Secrets

Everything sensitive lives in `.env` on the host, mounted via Compose's
`env_file`. The container itself never has secrets baked in. `.env` is
gitignored; `.env.example` is the source of truth for the schema.

`env_file` is all-or-nothing: the opencode service gets *every* key in `.env`,
so that file is exactly "what the agent may read". Anything a different
container needs and the agent must not see therefore cannot live there — it
belongs in a file that no `env_file:` directive names, handed to its own
service through that service's own `environment:` block.

## The credential model

Two switches in this image relax a default-off restriction:
`ALLOW_REMOTE_GIT` (+ `GIT_REMOTE_ALLOWLIST`) on the git plane, and
`ALLOW_<SERVICE>_WRITE` (+ `<SERVICE>_WRITE_PROJECTS`) on the MCP API plane.
Both are useful and neither is load-bearing. This section says what is.

### The scoped token is the boundary

**Do not give the agent a personal access token.** A personal PAT carries your
whole identity: every group, every production repo you can reach. Nothing in
this container can claw that back, because the token *is* the authority.

Prefer the narrowest thing that does the job:

1. **A project access token**, when the stack works one project — the normal
   case, since a GitLab project holds exactly one repository. Role
   **Developer**, scopes `api` + `write_repository`. One project, one repo, one
   issue tracker.
2. **A group access token** over a dedicated group, only once you want several
   repos under one credential. Same role and scopes.

Either way every other project returns 404. Not "denied" — invisible. A
confused agent, a hallucinated remote, a prompt injection out of an issue
comment: all of them hit a server-side authorization check that does not read
English.

Be precise about what constrains what: **`api` is full API access for that
project** — there is no issues-only scope. It is the **role** that stops a
token pushing code. Effective permission is scope × role, so get the role
right.

Then, all free and server-side, in the project or group settings: protect
`main` so no one may push and merges go through an MR; require at least one
approval; grant Developer rather than Maintainer, so the token cannot change
project settings or delete repos.

### Credential absence removes capability

Each MCP server in this image auto-enables on credential presence. A stack that
should not reach Confluence does not disable the Confluence MCP — it leaves
`CONFLUENCE_PAT` empty, and the server is then never wired into `opencode.json`
at all. Not disabled: absent.

This is why `.env.example` ships every credential key blank rather than
omitting the ones you probably don't need. An empty value is how you say "not
here".

### The two gates are defence in depth, not boundaries

`GIT_REMOTE_ALLOWLIST` and `<SERVICE>_WRITE_PROJECTS` both narrow *where* an
enabled capability may act, using the same path-segment prefix rule so there is
one thing to learn. Neither contains a determined agent: it has a shell and a
token, and can call `/usr/bin/git` past the PATH shim or `curl` the API
directly.

What they buy is that write capability is off unless someone deliberately
turned it on, that the tools the model is offered match what the deployment
intends, and that a mistake — a stale branch config, a pasted URL, a
hallucinated remote — becomes a legible local error instead of a confusing 403.
Do not let either substitute for a correctly scoped token.

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
- **TeamCity CI.** Build on push to `main` and publish a version-tagged
  image automatically. Today this is done manually (see `MAINTAINERS.md`).
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
