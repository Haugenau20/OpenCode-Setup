# Troubleshooting

## `./scripts/doctor.sh` first

Most setup mistakes are caught by:

```
./scripts/doctor.sh
```

Run it before opening a ticket. It checks `.env`, the corp CA, and squid
reachability.

## "permission denied" on files in `/workspace`

You're hitting a UID mismatch between the host and the container's `dev`
user. Make sure `.env` has:

```
HOST_UID=$(id -u)
HOST_GID=$(id -g)
```

…then `docker compose down && docker compose up -d`. The entrypoint remaps
the `dev` user to match.

## The web UI / desktop app says "connection refused"

Check the port is published and not in use elsewhere:

```
docker compose ps
ss -ltnp | grep :4096
```

Set a different `OPENCODE_PORT` in `.env` if 4096 is taken.

## Git push refused: "set ALLOW_REMOTE_GIT=1"

That's the safety gate doing its job. See
[ALLOWING_GIT_PUSH.md](ALLOWING_GIT_PUSH.md).

## "x509: certificate signed by unknown authority"

The corp CA wasn't baked into the image. The image needs to be rebuilt
after the maintainer drops the CA in `ca/`.

If you're the maintainer and just added the CA: `docker compose build
--no-cache opencode`.

## Squid is blocking something I need

Check the URL is on the allowlist:

```
docker compose logs squid | grep TCP_DENIED
```

To add an entry yourself, see "Per-developer allowlist additions" in the
top-level [README](../README.md). Or open a PR if it should ship to
everyone.

## Container won't start, exit code from entrypoint

```
docker compose logs opencode
```

The entrypoint prints what step it failed on (CA install, UID remap, config
merge, server start). Match the message to the line in
`opencode/entrypoint.sh`.

## Two stacks fighting for the same port

You started a second project without changing `PROJECT_SLUG` and
`OPENCODE_PORT` in its `.env`. Pick different values, `docker compose down`
the duplicate, then `up -d`.

## Nothing is being saved between restarts

You set `ENABLE_SESSION_LOGS=0`. That swaps the session state volume for
tmpfs. Flip back to `1` if you want persistence.

## I broke my user layer

```
docker compose down
docker volume rm opencode-${PROJECT_SLUG}_oc_cfg_${PROJECT_SLUG}
docker compose up -d
```

This wipes your per-project user-layer config. The image's bundled
agents/skills/etc. are unaffected.
