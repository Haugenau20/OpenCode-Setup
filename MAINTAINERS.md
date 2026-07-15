# Maintainers

You maintain this repo; developers consume it. This document is for you.

## Cutting a release

Releases are version-numbered image tags pushed manually to Artifactory. The
current version lives in the top-level **`VERSION`** file — the single source of
truth. To cut a release, first bump `VERSION` to the next semver number (e.g.
`0.2.0`), then the steps below read it back with `$(cat VERSION)`.

```
# bump the VERSION file first, then load it here
VERSION=$(cat VERSION)

# 0. run the local gate — bash -n/shellcheck, JSON validity, node --check on
#    the MCP servers, and the bats suite under tests/; also runs the
#    docker-dependent checks below (image builds, squid -k parse, the smoke
#    test) if a Docker daemon is reachable, otherwise lists them as manual
#    reminders. This is also what becomes the CI job once CI infra exists.
./scripts/check.sh

# 1. update CHANGELOG.md: rename [Unreleased] to [$VERSION] with today's
#    date, fill in the "Action required" line, and commit it (together with
#    the VERSION bump).
# 2. drop the real corp CA into ca/  (it's gitignored)
# 3. build both images, tagged with the version. --build-arg IMAGE_VERSION on
#    the opencode build stamps the OCI version label AND gets baked into
#    /etc/opencode/manifest.json (the squid image carries neither — it has no
#    manifest).
docker build -f opencode/Dockerfile -t artifactory.internal.example/opencode-workplace:$VERSION \
    --build-arg IMAGE_VERSION=$VERSION .
docker build -f squid/Dockerfile    -t artifactory.internal.example/opencode-workplace-squid:$VERSION .

# 4. smoke-test (see "Smoke test")

# 5. push to artifactory
docker push artifactory.internal.example/opencode-workplace:$VERSION
docker push artifactory.internal.example/opencode-workplace-squid:$VERSION
```

Then tell developers: point their `.env` at `IMAGE_TAG=$VERSION` and link
them to the CHANGELOG entry — the "Action required" line tells them whether
a rerun is enough or they also need to update the launcher / edit `.env`.

### The image manifest (`/etc/opencode/manifest.json`)

`opencode/manifest.json` is the checked-in source of truth for what THIS
image consumes: the env keys the container reads, the MCP servers it ships,
and the plugins it bakes. At build time the Dockerfile injects the real
`image_version`/`opencode_version` (from the `IMAGE_VERSION`/`OPENCODE_VERSION`
build args) and writes the result to `/etc/opencode/manifest.json` in the
image. The launcher reads this file (via `docker run --rm <img> cat
/etc/opencode/manifest.json`, or an equivalent `docker inspect`/exec) to diff
its own known env schema against the image's and warn loudly on drift —
see the launcher's own docs for the check itself.

**Rule: when you add an env key the container reads — a new service's
`_BASE_URL`/`_USER`/`_PAT`, a new `DISABLE_*_MCP` toggle, anything the
entrypoint or an MCP server reads via `process.env`/`${VAR}` — add it to
`opencode/manifest.json`'s `env_keys` in the SAME commit.** Same discipline
for `mcps` and `plugins` when either list changes. This is what keeps the
launcher's drift check honest; a key the image reads but the manifest doesn't
list is invisible to it.

## Smoke test

```
PROJECT_SLUG=smoke OPENCODE_PORT=4099 IMAGE_TAG=$VERSION \
    docker compose up -d
./scripts/doctor.sh
./scripts/opencode --help
PROJECT_SLUG=smoke docker compose down
```

`doctor.sh` checks the LLM endpoint is reachable through squid, which is
the most failure-prone part.

## Updating opencode itself

Bump the `OPENCODE_VERSION` build arg in `opencode/Dockerfile` (or pass it
explicitly: `--build-arg OPENCODE_VERSION=0.x.y`). The exact version is
recorded as an OCI label so developers can `docker inspect` to see what
they have.

## Adding to the workplace bundle (agents/skills/commands)

Drop files under `opencode/bundle/{agents,skills,commands,mcp}/` and cut a
new tag. Developers pick them up by pulling. They can disable individual
items via their `disabled.yaml` — see `docs/ADDING_SKILLS.md`.

## Changing the squid allowlist

Edit (or add) files under `squid/allowlist.d/`. Each file is one logical
service. Filenames are numeric-prefixed for ordering but order does not
actually matter for allowlist ACLs.

After changing the allowlist, `docker compose build squid` and ship.

## The squid base image

`squid/Dockerfile` pins `FROM ubuntu/squid:<tag>@<digest>` — the `ubuntu/squid`
repo on Docker Hub doesn't publish plain numbered release tags, only
`<squid-version>-<ubuntu-version>_beta` / `_edge` channel tags plus the
floating `latest`/`edge` aliases, so the pin is "whatever `latest` resolved
to on the day it was last checked", recorded explicitly instead of tracked
implicitly. Before building a release (or whenever it's been a while), re-pin
deliberately rather than silently drifting on `latest`:

```
docker pull ubuntu/squid:latest
docker inspect --format '{{index .RepoDigests 0}}' ubuntu/squid:latest
```

Cross-check the resolved tag/digest against
`https://hub.docker.com/v2/repositories/ubuntu/squid/tags` to pick the actual
`<squid>-<ubuntu>_beta` tag name it corresponds to (`latest` is an alias, not
a tag you can pin directly), then update both the tag and the `@sha256:...`
digest in `squid/Dockerfile` and record the date/reasoning in the comment
above the `FROM` line. Bump with intent, same as `OPENCODE_VERSION`.

## Corp CA

The CA itself never enters this repo. Drop it in `ca/` immediately before
building. Both the opencode and squid images consume it. In CI the cert
should come from a TeamCity-managed secret.

## Future maintenance items

- TeamCity build pipeline (planned).
- `/report-bug` slash command (sketched, unimplemented). Should post a
  redacted bundle of the last session to a JIRA project via the already-
  allowlisted JIRA API.
- RAG MCP server. When it ships, add it to `opencode/bundle/mcp/rag.yaml`
  pointing at `http://rag:PORT` and run it as a third compose service on
  the `oc_internal` network.
