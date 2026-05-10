# Maintainers

You maintain this repo; developers consume it. This document is for you.

## Cutting a release

Today (pre-CI):

```
# 1. drop the real corp CA into ca/  (it's gitignored)
# 2. build
docker build -f opencode/Dockerfile -t artifactory.internal.example/opencode-workplace:staging .
docker build -f squid/Dockerfile    -t artifactory.internal.example/opencode-workplace-squid:staging .

# 3. push to artifactory
docker push artifactory.internal.example/opencode-workplace:staging
docker push artifactory.internal.example/opencode-workplace-squid:staging

# 4. smoke-test (see "Smoke test")

# 5. promote to prod
docker tag  artifactory.internal.example/opencode-workplace:staging \
            artifactory.internal.example/opencode-workplace:prod
docker tag  artifactory.internal.example/opencode-workplace-squid:staging \
            artifactory.internal.example/opencode-workplace-squid:prod
docker push artifactory.internal.example/opencode-workplace:prod
docker push artifactory.internal.example/opencode-workplace-squid:prod
```

Later, TeamCity will do this automatically on push to `main` (with a manual
promotion step for `:prod`).

## Smoke test

```
PROJECT_SLUG=smoke OPENCODE_PORT=4099 docker compose -f docker-compose.yml \
    -f docker-compose.staging.yml up -d
./scripts/doctor.sh
./scripts/opencode --help
docker compose -f docker-compose.yml -f docker-compose.staging.yml down
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
