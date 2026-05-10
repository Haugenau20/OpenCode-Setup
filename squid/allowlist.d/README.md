# Squid allowlist

Each `*.conf` here contributes one or more `acl allowed_dst dstdomain ...`
entries. They are concatenated into the running squid config via
`include /etc/squid/allowlist.d/*.conf`.

## Workplace entries (shipped)

- `00-llm.conf` — the LLM endpoint
- `10-bitbucket.conf` — the Bitbucket server (both git and REST API)
- `20-jira.conf` — the JIRA server

Replace the example hostnames with the real internal ones before building
the production image.

## Per-developer additions

Developers can add their own entries without rebuilding the image. Drop a
`*.conf` file into `extra-allowlist.d/` next to `docker-compose.yml`. The
directory is gitignored and bind-mounted into the squid container. Same
syntax as the shipped files:

```
# extra-allowlist.d/my-tool.conf
acl allowed_dst dstdomain .my-internal-tool.example
```

`docker compose restart squid` applies the change.
