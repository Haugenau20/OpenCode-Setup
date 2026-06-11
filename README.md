# OpenCode Workplace

A locked-down Docker setup for running [OpenCode](https://opencode.ai/)
against the company's internal LLM endpoint. Egress is restricted to a
short allowlist via a Squid sidecar; nothing else gets in or out.

You get one image that serves the TUI, the web UI, and the desktop app from
a single backend. They share the same sessions and state — but see the
known web-UI limitation below, which is why the **TUI is the recommended
frontend** right now.

> [!WARNING]
> **OpenCode upstream bug — the web UI / desktop app start in `/`, not `/workspace`.**
> On the OpenCode version baked into the image (**1.16.2** — the latest
> release as of 2026-06), `opencode serve` roots the **web UI and desktop
> app** at `/` instead of your mounted repo, and there is no flag/config to
> override it on this version. The agent then reads from `/` and writes fail
> or land in the wrong place.
>
> - **The TUI is unaffected.** `./scripts/opencode` and the launcher's
>   `--tui` pin it to `/workspace` — prefer the TUI.
> - **If you use the web UI / desktop anyway**, make your *first prompt* tell
>   the agent to `cd /workspace` and work from there for the rest of the
>   session.
>
> Tracking upstream: [opencode#14445](https://github.com/anomalyco/opencode/issues/14445),
> [opencode#14460](https://github.com/anomalyco/opencode/issues/14460).
> **Re-check on every image bump** — the fix has landed once
> `docker exec opencode-<slug> opencode serve --help` lists a `--cwd` flag.
> Full detail + the one-line fix to apply then:
> [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#web-ui--desktop-app-operates-from--instead-of-workspace).

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

That's it. `./scripts/opencode` drops you into the TUI, which is the
recommended frontend. The web UI is on `http://localhost:4096` (or whichever
`OPENCODE_PORT` you set) and the desktop app — install it from
[opencode.ai/download](https://opencode.ai/download) — connects to the same
URL, but both currently start in `/` rather than `/workspace` on OpenCode
1.16.2 (see the warning above before using them).

If something doesn't work, run `./scripts/doctor.sh` first.

## What you get

- OpenCode backend running as a non-root user in a container.
- All outbound traffic forced through Squid; allowlist is the LLM endpoint,
  Bitbucket, and JIRA.
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

A curated set of OpenCode plugins (superpowers, dynamic context pruning,
workspace planning/background-agents) is baked into the image but **off by
default**. Turn one on by listing it under `plugins.enabled` in
`~/.config/opencode/disabled.yaml`, then restart — no network required. Run
`/plugins` for the live catalog. Full details (and how to add your own) in
[`docs/ADDING_PLUGINS.md`](docs/ADDING_PLUGINS.md).

## Per-developer allowlist additions

Drop a `*.conf` file into `extra-allowlist.d/` (gitignored) and
`docker compose restart squid`. Same syntax as the shipped allowlist files
under `squid/allowlist.d/`. You are responsible for what you add.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full picture
(networks, image layout, config layering, telemetry stance).

## For the maintainer

See [`MAINTAINERS.md`](MAINTAINERS.md).

## Troubleshooting

[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).
