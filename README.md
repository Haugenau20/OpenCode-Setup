# OpenCode Workplace

A locked-down Docker setup for running [OpenCode](https://opencode.ai/)
against the company's internal LLM endpoint. Egress is restricted to a
short allowlist via a Squid sidecar; nothing else gets in or out.

You get one image that serves the TUI, the web UI, and the desktop app from
a single backend. Pick whichever frontend you like — they share the same
sessions and state.

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

That's it. The web UI is on `http://localhost:4096` (or whichever
`OPENCODE_PORT` you set). The desktop app — install it from
[opencode.ai/download](https://opencode.ai/download) — connects to the same
URL.

If something doesn't work, run `./scripts/doctor.sh` first.

## What you get

- OpenCode backend running as a non-root user in a container.
- All outbound traffic forced through Squid; allowlist is the LLM endpoint,
  Bitbucket, and JIRA.
- Bundled workplace agents/skills/commands you can extend or disable.
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
