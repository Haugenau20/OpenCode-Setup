# Troubleshooting

## `./scripts/doctor.sh` first

Most setup mistakes are caught by:

```
./scripts/doctor.sh
```

Run it before opening a ticket. It checks `.env`, the corp CA, and squid
reachability.

## Agents hit `PermissionDenied: FileSystem.writeFile` / can't edit or run commands

This is **opencode's own permission layer**, not a Linux file permission —
the tell is that even writes to `/tmp` are refused, and there's no UID fix
that helps. It happens because opencode's built-in per-agent defaults treat
`edit`/`bash` as `"ask"` for most agents, and we run headless (`opencode
serve`) where an unanswered `"ask"` resolves to a denial.

The shipped `opencode/opencode.json` pins an explicit policy so this can't
depend on shifting upstream defaults:

```json
"permission": {
  "edit": "allow",
  "webfetch": "deny",
  "bash": "allow"
}
```

This is safe because the container is already the security boundary: egress
is forced through the Squid allowlist and remote git is gated by
`git-guard`. `webfetch` is `deny` on purpose — the Squid proxy blocks
arbitrary outbound HTTP anyway, so there's no reason to let an agent think
it can reach the open internet. If you still get denials, you're probably on an old image or a
project-level `opencode.json` in `/workspace` is overriding the shipped one
(see "LLM API errors" below) — rebuild with `docker compose build opencode`
and check for a repo-root config.

## "permission denied" on files in `/workspace`

You're hitting a UID mismatch between the host and the container's `dev`
user (a Linux ownership problem — distinct from the opencode permission
layer above). Make sure `.env` has:

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

4. Confirm the publisher sidecar is publishing the port. The host port is
   exposed by the `oc-publish` socat forwarder, **not** by `opencode` itself
   (opencode is on internal-only networks and Docker 28+ won't bind host ports
   there — this is intentional to preserve the no-egress guarantee):

   ```
   docker ps --format '{{.Names}}\t{{.Ports}}' | grep opencode
   ss -ltnp | grep 4096          # host should show 127.0.0.1:4096 listening
   ```

   You should see `opencode-publish-<slug>` with `127.0.0.1:4096->4096/tcp`,
   while `opencode-<slug>` correctly shows only `4096/tcp` (internal by design).

   If `opencode-publish-<slug>` is missing from `docker ps`, the sidecar is
   not running: `docker compose up -d oc-publish`.

   The same sidecar also forwards the opencode-pty web viewer port when that
   plugin is enabled. That port is derived from `OPENCODE_PORT` by prepending a
   `1` (main `4096` → viewer `14096`). If you can't reach
   `http://localhost:14096`, run the same checks with that port in place of
   `4096`, and confirm the viewer's server is started (`/pty-open-background-spy`
   in the TUI) — it does not listen until then.

   If the sidecar is up but you get connection refused, check it can reach
   opencode:

   ```
   docker logs opencode-publish-<slug>
   docker exec opencode-publish-<slug> socat -T2 - TCP:opencode:4096 </dev/null
   ```

   If the port mapping itself is missing from `docker compose config`, check
   for an **inline `#` comment in `.env`** on the `OPENCODE_PORT` line — some
   parsers keep `4096   # comment` as the literal value and Compose drops the
   publish. Fix `.env` so the line is just `OPENCODE_PORT=4096` (comment on its
   own line), then `docker compose up -d --force-recreate oc-publish`. Run
   `./scripts/doctor.sh` — it flags inline comments in `.env`.

5. Test from the host while bypassing any corporate proxy — this is the most
   common cause in airgapped environments. Your shell likely exports
   `HTTP_PROXY`/`HTTPS_PROXY`, so `curl` routes the request through the corp
   proxy, which refuses it:

   ```
   curl -sv --noproxy '*' http://localhost:4096
   ```

   If this works but a browser does not, add `localhost,127.0.0.1` to the
   browser or OS no-proxy settings.

6. `OPENCODE_PORT` can be any free port. The **browser** web UI talks to
   whatever origin you loaded the page from, so remapping the host port works
   fine. (The **desktop app** defaults to `localhost:4096`; to point it at a
   different port, use its "add server" dialog.)

7. Squid is irrelevant here — it only governs the container's outbound traffic;
   inbound published ports do not go through it.

## Web UI / desktop app start a new session in `/` instead of `/workspace`

**Symptom.** In the **web UI or desktop app**, a new session's working
directory is `/` (root) instead of your mounted repo. The agent reads from `/`,
and writes fail or land in the wrong place. The **TUI does not have this
problem** — it always starts in `/workspace`.

**Fix — set the working directory when you start the session.** This is a
one-step action in the UI, not a config change:

1. Open the web UI (`http://localhost:${OPENCODE_PORT}`) or the desktop app.
2. Click **New session**.
3. When prompted for the working directory, type **`/workspace`**.

Everything in that session then runs inside `/workspace`. You set this per
session; existing sessions keep whatever directory they were created with.

> Things that do **not** fix it: appending `?directory=/workspace` to the URL,
> or telling the agent to `cd /workspace` in your first prompt. Use the
> New-session working-directory prompt above.

**Cause.** An upstream OpenCode behavior, not a fault in this setup. The image
is correct (`WORKDIR /workspace`, `CMD ["serve"]`) and the entrypoint hands off
to `opencode serve` from `/workspace`. The server resolves each request's
project directory from the client (an `x-opencode-directory` header), and the
web/desktop client defaults a brand-new session to `/` rather than the server's
working directory. Choosing `/workspace` in the New-session prompt sets that
header correctly for the session. The TUI sidesteps it because
`./scripts/opencode` (and the launcher's `--tui`) attach with
`docker exec … -w /workspace … opencode`, pinning the directory.
Tracking: [opencode#14445](https://github.com/anomalyco/opencode/issues/14445).

**Is it dangerous?** If you leave a session rooted at `/`, the agent can read
across the whole container filesystem. The container is the security boundary —
no internet egress (Squid allowlist), remote git gated by `git-guard` — so the
practical blast radius is the container itself, which is disposable: if a
session messes it up, restart fresh (`docker compose down && docker compose up
-d`). Setting `/workspace` at session start avoids it entirely.

**How to tell when it's fixed.** After bumping the image to a newer OpenCode,
click **New session** in the web UI without touching the working directory. If
it defaults to `/workspace` (the server's working directory) instead of `/`, the
upstream default has been fixed and the manual step is no longer needed.

## Git push refused: "set ALLOW_REMOTE_GIT=1"

That's the safety gate doing its job. See
[ALLOWING_GIT_PUSH.md](ALLOWING_GIT_PUSH.md).

## git prompts for `Username for 'https://…:8443'` at startup (or on fetch/push)

**Symptom.** One user — not everyone — gets an interactive git prompt right
before the TUI attaches (or on the first `fetch`/`pull`/`push`):

```
Username for 'https://bitbucket.internal.example:8443':
```

…even though `BITBUCKET_BASE_URL` is plain HTTP on `:7990` and `:8443` appears
**nowhere** in `.env` or this repo.

**This is a local, per-user problem — not a fault in this setup.** Two facts
pin it down:

1. **The `:8443` HTTPS URL comes from the Bitbucket server, not from us.**
   Bitbucket has a canonical *Base URL* (Admin → Server settings), and corp
   installs are usually fronted by a reverse proxy that terminates TLS. When a
   client reaches the raw HTTP connector (`http://…:7990`), the server answers
   `301 Location: https://…:8443` to force its canonical HTTPS address. git
   follows the redirect and then has to authenticate against the new URL — so
   the port and scheme in the prompt are the server's, not anything you chose.

2. **It's a *git* prompt, so it comes from the repo's remote — not from
   `BITBUCKET_BASE_URL`.** That env var is read only by the Bitbucket MCP
   server (the REST client), which sends its `Authorization` header
   programmatically and can never produce a terminal `Username for …` prompt.
   A `Username for …` prompt is always git talking to a git remote, and that
   remote lives in the `.git/config` of the repo you bind-mount at
   `/workspace` (`REPO_PATH`) — set **per user, on their host, at clone time**.

So the user whose clone points at `http://…:7990` hits the redirect; users who
cloned over SSH (`ssh://git@…`) or the canonical `https://…:8443` never do.
(For the op to run at all he also has `ALLOW_REMOTE_GIT=1`; otherwise
`git-guard` blocks fetch/pull/push outright.)

**Confirm it:**

```bash
# What is the repo's remote actually pointing at?
git -C <REPO_PATH> remote -v

# Prove the server-side redirect (look for "Location: https://…:8443"):
curl -sSI "http://bitbucket.internal.example:7990/scm/PROJ/repo.git/info/refs?service=git-upload-pack"

# Rule out a host-side url.insteadOf rewrite on his machine:
git -C <REPO_PATH> config --get-regexp '^url\.'
```

**Fix it** — point the remote at the same canonical address everyone else uses:

```bash
# SSH (sidesteps HTTP auth entirely, matches the README clone example):
git -C <REPO_PATH> remote set-url origin ssh://git@bitbucket.internal.example/scm/PROJ/repo.git
# …or the canonical HTTPS endpoint, so there is no redirect:
git -C <REPO_PATH> remote set-url origin https://bitbucket.internal.example:8443/scm/PROJ/repo.git
```

Also make sure that user's `.env` has `BITBUCKET_USER` **and** `BITBUCKET_PAT`
set for git-over-HTTPS. The in-container credential helper (`entrypoint.sh` §6)
only generates a Bitbucket arm when both are present; without it git can't
answer the prompt on its own even for a correctly-pointed remote. (The Bitbucket
*MCP* no longer needs `BITBUCKET_USER` — its REST API uses a Bearer PAT — but
git-over-HTTPS still does.)

**Get ahead of it fleet-wide.** Rather than fixing each clone by hand, set
`BITBUCKET_LEGACY_URL` in `.env` to the legacy URL that redirects (e.g.
`http://bitbucket.internal.example:7990`) alongside a canonical
`BITBUCKET_BASE_URL` (e.g. `https://bitbucket.internal.example:8443`). The
entrypoint then bakes a git `url.<canonical>.insteadOf <legacy>` rewrite into the
container's `.gitconfig`, so **any** mounted repo whose remote still points at
the legacy URL is transparently upgraded before git connects — no redirect, no
prompt, no per-user host change. Confirm it landed with:

```bash
docker exec opencode-<slug> git config --get-regexp '^url\.'
```

## git/curl fail with "could not resolve host" (but the MCP works)

**Symptom.** The Bitbucket/GitLab **MCP works**, yet a hand-run `git` or `curl`
against the same internal host fails — even with `ALLOW_REMOTE_GIT=1`:

```
fatal: unable to access 'https://bitbucket.corp.local:8443/…': Could not resolve host
# or:  CONNECT tunnel failed, response 503
```

An agent may wrongly conclude the server "needs VPN" or "isn't accessible." It
is — the working MCP proves the container can reach it through Squid.

**Cause — `NO_PROXY` matches your corp domain.** If `NO_PROXY` (in
`docker-compose.yml` / `policy.yaml`) contains a suffix that matches your host
— classically `.local` matching `bitbucket.corp.local` — then every
proxy-honoring client (`git`, `curl`) **bypasses Squid and connects directly**.
The container has no direct egress, so DNS/connect fails. The MCP escapes this
only because undici's `ProxyAgent` ignores `NO_PROXY` — which is why the REST
plane looks healthy while git is broken.

**Confirm** (forcing the proxy should succeed where the default fails):

```bash
# fails (bypasses squid, direct):
docker exec opencode-<slug> curl -sS -o /dev/null -w '%{http_code}\n' -x http://squid:3128 \
  https://bitbucket.corp.local:8443/rest/api/1.0/application-properties
# works (forces proxy, mirrors the MCP):
docker exec opencode-<slug> env no_proxy= NO_PROXY= curl -sS -o /dev/null -w '%{http_code}\n' \
  -x http://squid:3128 https://bitbucket.corp.local:8443/rest/api/1.0/application-properties
```

**Fix.** Remove the matching suffix (e.g. `.local`) from `NO_PROXY` in
`docker-compose.yml` **and** `policy.yaml`, then rebuild/recreate
(`docker compose up -d --build`). Keep only loopback and the docker sidecar
names (`opencode`, `squid`, `rag`) there — everything external must route
through Squid. (Shipped images from this repo already exclude `.local`.)

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

Squid logs **denied** requests only — unlisted destinations, a `CONNECT` to a
non-SSL port, or an unsafe port — never allowed traffic (that stays
unlogged on purpose, so conversation/LLM data is never retained). Denied
requests show up in the container's own log:

```
docker compose logs squid
```

Look for the denied hostname/port in the output, then add it to the
allowlist. To add an entry yourself, see "Per-developer allowlist additions"
in the top-level [README](../README.md). Or open a PR if it should ship to
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

## I broke my user layer

```
docker compose down
docker volume rm opencode-${PROJECT_SLUG}_cfg
docker compose up -d
```

This wipes your per-project user-layer config. The image's bundled
agents/skills/etc. are unaffected.
