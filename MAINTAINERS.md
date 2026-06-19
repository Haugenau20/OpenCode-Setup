# Maintainers

You maintain this repo; developers consume it. This document is for you.

## Cutting a release

Releases are version-numbered image tags pushed manually to Artifactory.
Pick the next version (semver, e.g. `0.0.6`) and use it everywhere below.

```
VERSION=0.0.6

# 1. update CHANGELOG.md: rename [Unreleased] to [$VERSION] with today's
#    date, fill in the "Action required" line, and commit it.
# 2. drop the real corp CA into ca/  (it's gitignored)
# 3. build both images, tagged with the version
docker build -f opencode/Dockerfile -t artifactory.internal.example/opencode-workplace:$VERSION .
docker build -f squid/Dockerfile    -t artifactory.internal.example/opencode-workplace-squid:$VERSION .

# 4. smoke-test (see "Smoke test")

# 5. push to artifactory
docker push artifactory.internal.example/opencode-workplace:$VERSION
docker push artifactory.internal.example/opencode-workplace-squid:$VERSION
```

Then tell developers: point their `.env` at `IMAGE_TAG=$VERSION` and link
them to the CHANGELOG entry — the "Action required" line tells them whether
a rerun is enough or they also need to update the launcher / edit `.env`.

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
