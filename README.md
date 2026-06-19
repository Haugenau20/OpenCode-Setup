# OpenCode Workplace

A locked-down Docker setup for running [OpenCode](https://opencode.ai/)
against the company's internal LLM endpoint. Egress is restricted to a
short allowlist via a Squid sidecar; nothing else gets in or out.

You get one image that serves the TUI, the web UI, and the desktop app from
a single backend. They share the same sessions and state. The **TUI is the
simplest frontend** — it needs zero setup and always starts in `/workspace`.
The web UI and desktop app work too (on any port); they just need one extra
step per session, described below.

> [!NOTE]
> **Web UI / desktop app: set the working directory to `/workspace` when you
> start a session.** On the current OpenCode version, the web UI and desktop
> app default a **new session's** working directory to `/` instead of your
> mounted repo. The fix is a single step in the UI — not a config change, a URL
> parameter, or a prompt to the agent:
>
> 1. Open the web UI (`http://localhost:${OPENCODE_PORT}`) or the desktop app.
> 2. Click **New session**.
> 3. When prompted for the working directory, type **`/workspace`**.
>
> Everything in that session then runs inside `/workspace`. (The **TUI** skips
> this entirely — `./scripts/opencode` and the launcher's `--tui` always start
> in `/workspace`.)
>
> Tracking upstream: [opencode#14445](https://github.com/anomalyco/opencode/issues/14445).
> Full detail:
> [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#web-ui--desktop-app-start-a-new-session-in--instead-of-workspace).

## Quickstart (developers)

You must be a member of the `docker` group on your host. If you aren't:
`sudo usermod -aG docker $USER && newgrp docker`.

```
git clone ssh://git@bitbucket.internal.example/opencode-workplace.git
cd opencode-workplace
cp .env.example .env
$EDITOR .env                  # fill in LLM_API_KEY + BITBUCKET_PAT
docker compose up -d
./scripts/opencode            # opens the TUI; prints the web UI URL
```

That's it. `./scripts/opencode` drops you into the TUI, the simplest frontend.
The web UI is on `http://localhost:4096` (or whichever `OPENCODE_PORT` you set)
and the desktop app — install it from
[opencode.ai/download](https://opencode.ai/download) — connects to the same
URL. Both work on any port; just set the session working directory to
`/workspace` when you start one (see the note above).

If something doesn't work, run `./scripts/doctor.sh` first.

## What you get

- OpenCode backend running as a non-root user in a container.
- All outbound traffic forced through Squid; allowlist is the LLM endpoint,
  Bitbucket, GitLab, and JIRA.
- Bundled workplace agents/skills/commands you can extend or disable.
- A curated set of OpenCode plugins baked in but **off by default** — opt in per
  developer, no network needed. Run `/plugins` to see them.
- A git safety gate: remote operations (`push`, `fetch`, `pull`, `clone`)
  are blocked unless `ALLOW_REMOTE_GIT=1` in `.env`.
- Per-project persistent session/conversation logs (toggle off if you don't
  want them on disk).
- Three-network docker topology so opencode has no direct route to the
  internet.

## Working on more than one repo

Each repo gets its own clone of this scaffold and its own `.env` (different
`PROJECT_SLUG` and `OPENCODE_PORT`):

```
./scripts/new-project.sh myservice ~/code/myservice
cd ../OpenCode-Setup-myservice
$EDITOR .env
docker compose up -d
```

## Allowing git push

Off by default. See [`docs/ALLOWING_GIT_PUSH.md`](docs/ALLOWING_GIT_PUSH.md).

## Adding your own agents / skills / commands

Three scopes (image, you-only, this-repo). See
[`docs/ADDING_SKILLS.md`](docs/ADDING_SKILLS.md).

## Plugins

A curated set of OpenCode plugins is baked into the image but **off by default**.
Turn them on the same way as every other switch — a line in `.env`:

```
ENABLED_PLUGINS=superpowers dcp
```

then restart. No network required. Run `/plugins` in the TUI for the live
catalog. Full details (and how to add your own) in
[`docs/ADDING_PLUGINS.md`](docs/ADDING_PLUGINS.md).

### What's baked in (and where it comes from)

Every plugin is vendored at build time from a **pinned** upstream ref (the
versions below are the source of truth in
[`opencode/Dockerfile`](opencode/Dockerfile)). Use the names in the **Name**
column in `ENABLED_PLUGINS`.

| Name | What it does | Upstream | Pinned |
|------|--------------|----------|--------|
| `superpowers` | Skills library: brainstorming, writing-plans, systematic-debugging, TDD, requesting/receiving code review, and more. | [obra/superpowers](https://github.com/obra/superpowers) | `v5.1.0` (`6fd4507`) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens (no user-facing tool). | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) | `v3.1.12` |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). Only the two container-safe plugins are shipped. | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) | `4451c68` |

> [!WARNING]
> **Do not enable `opencode-workspace` if you use Qwen.** The extra tools and
> system prompt it injects are rejected by Qwen's upstream, so every prompt then
> fails with `AI_APICallError: Failed to communicate with the upstream service`.
> Other models (e.g. MiniMax, Gemma) are unaffected. Leave this plugin disabled
> when working with Qwen.


## MCP servers (Bitbucket, GitLab & Jira)

Three first-party, **read-only** MCP servers ship in the image, giving the agent
direct access to the internal Bitbucket, GitLab, and Jira instances (PRs/MRs,
diffs, commits, files; issues + JQL search). Each **auto-enables when its
credentials are set** in `.env` — no separate switch — and a single PAT per
service serves both git and the REST API, so no account password is stored.
Bitbucket and GitLab also act as git remotes over HTTPS. Full detail (env vars,
the HTTP-vs-HTTPS gotcha, TLS, adding more services) in
[`docs/MCP_SERVERS.md`](docs/MCP_SERVERS.md).

## Per-developer allowlist additions

Drop a `*.conf` file into `extra-allowlist.d/` (gitignored) and
`docker compose restart squid`. Same syntax as the shipped allowlist files
under `squid/allowlist.d/`. You are responsible for what you add.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full picture
(networks, image layout, config layering, telemetry stance).

## What's new

Per-version notes — what changed and whether you need to do more than rerun —
are in [`CHANGELOG.md`](CHANGELOG.md).

## For the maintainer

See [`MAINTAINERS.md`](MAINTAINERS.md).

## Troubleshooting

[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).
