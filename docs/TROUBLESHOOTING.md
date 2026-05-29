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

## Can't reach http://localhost:4096

Work through this ladder in order:

1. Confirm the container is up:

   ```
   docker compose ps
   ```

   The `opencode` service should show "Up".

2. Confirm the server started without crashing:

   ```
   docker compose logs opencode | tail -n 30
   ```

   Look for the `starting opencode: serve` line and no stack trace after it.

3. Confirm it is listening inside the container on `0.0.0.0:4096` (not
   `127.0.0.1:4096`):

   ```
   docker exec opencode-<slug> ss -ltnp | grep 4096
   ```

4. Confirm Docker actually published the port. `docker ps` should show
   `127.0.0.1:4096->4096/tcp` — **not** a bare `4096/tcp` (that is only the
   Dockerfile `EXPOSE`, meaning nothing is published):

   ```
   docker ps --format '{{.Names}}\t{{.Ports}}' | grep opencode
   ss -ltnp | grep 4096          # host should show 127.0.0.1:4096 listening
   ```

   If the mapping is missing, check how Compose resolved it:

   ```
   docker compose config | grep -A3 'ports:'
   ```

   A correct mapping has a `published: "4096"` line. If `published:` is absent,
   the value of `OPENCODE_PORT` is malformed — almost always an **inline `#`
   comment in `.env`**. Some `docker compose` parsers keep `4096   # comment` as
   the literal value, so the host-port token is garbage and Compose drops the
   publish. Fix `.env` so the line is just `OPENCODE_PORT=4096` (comment on its
   own line), then `docker compose up -d --force-recreate opencode`. Run
   `./scripts/doctor.sh` — it now flags inline comments in `.env`.

   Note: this is unrelated to the `internal: true` networks. Published ports
   work fine from internal-only networks — the host reaches the container via
   the internal bridge's gateway address; `internal: true` only removes the
   container's *outbound* route. You do not need to make any network external.

5. Test from the host while bypassing any corporate proxy — this is the most
   common cause in airgapped environments. Your shell likely exports
   `HTTP_PROXY`/`HTTPS_PROXY`, so `curl` routes the request through the corp
   proxy, which refuses it:

   ```
   curl -sv --noproxy '*' http://localhost:4096
   ```

   If this works but a browser does not, add `localhost,127.0.0.1` to the
   browser or OS no-proxy settings.

6. Keep `OPENCODE_PORT=4096`. The web/desktop frontend hardcodes port 4096 in
   its API calls (upstream bug), so remapping the host port leaves the page
   loading but unable to reach the backend.

7. Squid is irrelevant here — it only governs the container's outbound traffic;
   inbound published ports do not go through it.

## Git push refused: "set ALLOW_REMOTE_GIT=1"

That's the safety gate doing its job. See
[ALLOWING_GIT_PUSH.md](ALLOWING_GIT_PUSH.md).

## "x509: certificate signed by unknown authority"

The corp CA wasn't baked into the image. The image needs to be rebuilt
after the maintainer drops the CA in `ca/`.

If you're the maintainer and just added the CA: `docker compose build
--no-cache opencode`.

## LLM API errors / 'Unauthorized' when prompting a model

Credentials are written at container start to `/home/dev/secrets/llm_api_base`
and `/home/dev/secrets/llm_api_key` (mode 0600, owned by the `dev` user) and
referenced from `opencode.json` via `{file:...}`. Verify the values landed
cleanly:

```
docker exec opencode-<slug> cat /home/dev/secrets/llm_api_key
```

If the output contains stray quotes or whitespace, they leaked in from `.env`
(docker `env_file` passes quote characters literally). Remove them from `.env`
— the entrypoint strips one layer of surrounding quotes/whitespace, but nested
or mismatched quoting can still slip through.

opencode merges config files in order of precedence, and a project-level
`opencode.json` or `opencode.jsonc` in your mounted repo (`/workspace`) will
**override** the shipped config. If prompts are hitting the wrong provider,
check for such a file at the repo root.

The shipped config path is pinned via the `OPENCODE_CONFIG` environment
variable set by the entrypoint, so opencode loads exactly
`~/.config/opencode/opencode.json` rather than auto-discovering one.

## Squid is blocking something I need

Check the URL is on the allowlist:

```
docker compose logs squid | grep TCP_DENIED
```

To add an entry yourself, see "Per-developer allowlist additions" in the
top-level [README](../README.md). Or open a PR if it should ship to
everyone.

## Squid won't start: `ACL 'allowed_dst' already exists with different type`

```
aclParseAclLine: ACL 'allowed_dst' already exists with different type.
FATAL: Bungled .../allowlist.d/10-bitbucket.conf line N: acl allowed_dst port 7990
```

You added a `port` (or other non-`dstdomain`) ACL reusing the name
`allowed_dst`. Squid allows reusing a name only with the **same** type, so
`dstdomain` + `port` is fatal. Ports are not configured in `allowlist.d/` at
all — those files are `dstdomain` only.

To allow git/HTTPS to a non-standard TLS port (Bitbucket's default is 7990),
add it to `SSL_ports` in `squid/squid.conf` (already shipped for 7990 and
8443), not to the allowlist:

```
acl SSL_ports port 7990
```

Without that, `http_access deny CONNECT !SSL_ports` blocks the `CONNECT`
tunnel and clones/pushes fail. Then `docker compose build squid && docker
compose up -d squid`.

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
