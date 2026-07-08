# Changelog

All notable changes to the OpenCode Workplace image are documented here. The
version numbers match the image tags pushed to Artifactory (e.g. `0.0.5`), so
a developer who runs `docker inspect` on their image can map it straight to a
section below.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## How to read the "Action required" line

Every release carries one line telling consumers what they must do to pick it
up. The vocabulary:

- **rerun only** — just re-launch (`./scripts/opencode` / the launcher). No new
  image, no config change.
- **re-pull image** — a new image tag exists; set `IMAGE_TAG` to the new
  version and `docker compose pull`.
- **edit .env** — a variable was added or renamed; update your `.env`.
- **rebuild squid** — the allowlist or squid config changed; rebuild/repull
  the squid image.
- **update launcher** — the launcher repo needs a matching change.

> [!NOTE]
> Versions **0.0.1–0.0.5** were reconstructed from git history after the fact,
> so the version boundaries, dates, and "Action required" lines are
> best-effort. Adjust them where you know better — newer releases should be
> written at release time and will be accurate.

## [0.0.7] — 2026-07-07

**Action required:** re-pull image + rebuild squid. If your `.env` still sets
`ENABLE_SESSION_LOGS`, delete it — it is no longer read. Pairs with a launcher
change (see the `OPENCODE_EXTRA_*` notes below) to make `--also` folders both
discoverable and accessible without a per-access prompt.

### Added
- **`OPENCODE_EXTRA_INSTRUCTIONS`** — a generic hook for surfacing context that
  lives outside the project root. It's a space/comma-separated list of extra
  instruction files (absolute container paths); at boot the entrypoint appends
  each to the generated `opencode.json`'s `instructions` array, which opencode
  concatenates with the `AGENTS.md` files. Guaranteed no-op when unset.

  This exists to fix a real gap: the launcher's `--also <path>` mounts extra
  folders at `/workspace-extra/<name>` (siblings of the repo at `/workspace`),
  but opencode runs with `/workspace` as its project root and its file tools
  never look outside it, so those mounts were undiscoverable by an open-ended
  search. Rather than teach the image about the launcher's private mount layout,
  the image just honors this generic var; the **launcher** generates a breadcrumb
  naming its `--also` folders and points the var at it (launcher ≥ the matching
  release). The whole `--also` feature — what to advertise, the wording, the
  path convention — stays maintained in the launcher; the image contributes only
  this stable primitive. Kept out of `manifest.json`/`.env.example` on purpose:
  it is internal launcher→image plumbing (injected by the launcher's `--also`
  compose overlay), never a user-set knob, so it is not surfaced as a documented
  env key. New tests cover the parser and the `instructions` jq wiring.
- **`OPENCODE_EXTRA_ALLOWED_DIRS`** — the *access* companion to the hook above.
  OpenCode gates any tool call touching a path outside the `/workspace` project
  root behind its `external_directory` permission (default `ask`), so the
  launcher's `--also` mounts were now discoverable via the breadcrumb but still
  popped an "Access external directory" confirmation on every read/edit under
  them. This space/comma-separated list of path globs is folded into the
  generated `opencode.json`'s `permission.external_directory` as `allow` at boot
  (only the listed globs; every other out-of-project path keeps the `ask`
  default). Same generic, launcher-injected contract as
  `OPENCODE_EXTRA_INSTRUCTIONS` — the launcher sets it to `/workspace-extra/**`
  and the image never learns the mount layout — and likewise kept out of
  `manifest.json`/`.env.example`. New tests cover the parser and the
  `external_directory` jq wiring.
- **Machine-readable image manifest** (`/etc/opencode/manifest.json`) listing
  every env key the container reads, the MCP servers it ships, and the baked
  plugins — the source the launcher's drift check reads to spot services it
  doesn't know about yet.
- **In-image `CHANGELOG.md`** (`/etc/opencode/CHANGELOG.md`) so a running
  container carries its own release notes.
- **Local test harness** (`tests/`, bats): `git-guard`, `entrypoint.sh` helpers,
  and repo-wide static invariants (manifest ↔ `.env.example`/MCP dirs/Dockerfile
  agree, allowlist syntax, `bash -n`/`node --check`, JSON parses). 67 tests.
- **`scripts/check.sh`** — one-command pre-release gate (`bash -n`, shellcheck,
  JSON validation, `node --check`, the `tests/` suite; plus both image builds
  and `squid -k parse` when a Docker daemon is reachable).

### Fixed
- **`git-guard` global-option bypass**: `git -C <path> push`, `git -c k=v fetch`,
  `git --git-dir=… pull`, etc. skipped the `ALLOW_REMOTE_GIT` gate because only
  `$1` was inspected; it now finds the real subcommand first. `ls-remote` is now
  gated too.
- **`policy.yaml` values kept their literal quotes** when exported (e.g. a quoted
  `NO_PROXY` overwrote the correct value compose set). The parser now strips one
  layer of surrounding quotes.
- **Git credential helper matched hosts by suffix glob**, so a lookalike like
  `evil-bitbucket.internal.example` would also receive real credentials. Matching
  is now exact-host.
- **`disabled.yaml` inline-array forms misbehaved** (`agents: [code-reviewer]`,
  same-line `skills: []`, multi-item dash lists disabled nothing, the wrong
  kind, or only the first entry). The parser now handles every documented form,
  in any mix, per kind.

### Changed
- **Squid logs denied requests** (unlisted destination, disallowed `CONNECT`
  port, unsafe port) to `docker compose logs squid`, making self-service
  allowlist debugging possible. Allowed traffic — including all LLM/conversation
  data — is still never logged, so the no-retention stance is unchanged. squid
  writes them to a file that the container entrypoint tails to stdout (it can't
  open `/dev/stdout` itself once it drops to the `proxy` user).
- **Pinned the squid base image** to `ubuntu/squid:6.6-24.04_beta` by digest
  (was `:latest`), matching the deliberate pinning used for `OPENCODE_VERSION`.
  See MAINTAINERS.md for the re-pin recipe.
- **Removed passwordless `sudo`** for the `dev` user and dropped the `sudo`
  package from the image. Nothing legitimate used it (the UID remap runs as root
  in the entrypoint before dropping to `dev` via `gosu`), and it allowed
  re-owning the host workspace bind mount from inside the container.
- **`entrypoint.sh` boot flow wrapped in `main()`** behind a source-guard so its
  pure helpers can be unit-tested by sourcing the file. Pure code-motion
  refactor; the only logic change is the inline §7 policy loop extracted as the
  reusable `apply_policy_env FILE`. **PID-1-critical — needs a `docker build` +
  container boot smoke test before it ships** (see MAINTAINERS.md step 0).
- **MCP credential gating is now a table walk** in both `entrypoint.sh` and
  `scripts/doctor.sh` (was five hand-copied `if` blocks each), so adding a sixth
  service is a one-row diff. Behavior verified byte-for-byte unchanged.
- **New shared MCP helper lib** (`opencode/mcp-servers/_lib/common.js`) for the
  proxy dispatcher, env validation, auth headers, `jsonGet`, and error
  formatting all five servers had duplicated; all migrated onto it with no
  change to tool names, schemas, or output.
- **Bitbucket MCP server normalized onto `McpServer`/`server.tool(...)`**,
  matching Jira/Confluence (GitLab and JFrog still use the low-level API); tool
  surface unchanged.
- **MCP tool errors no longer include `err.stack`** — message (and cause) only,
  via a shared `toolError()` helper. A raw stack trace was token noise that never
  explained *why* a request failed.
- **`NODE_MAJOR` bumped `20` → `22`** in `opencode/Dockerfile` (Node 20 is EOL
  April 2026). The MCP servers are pure undici/zod; validated with `node --check`.
- **`scripts/doctor.sh` treats Bitbucket credentials as optional**, matching
  `.env.example` and the launcher (unset now warns instead of failing).

### Removed
- **`ENABLE_SESSION_LOGS` knob** — it never worked. Disabling it tried to mount a
  tmpfs over the state dir, which needs `CAP_SYS_ADMIN` that compose never
  grants, so session logs were always persisted anyway. Removed the dead code,
  the `.env.example` entry, and its docs; an old `.env` that still sets it is
  harmlessly ignored.

## [0.0.6] — 2026-06-26

**Action required:** re-pull image + rebuild squid + edit .env (new MCP credentials)

### Added
- Read-only **JFrog Artifactory MCP server** (`opencode/mcp-servers/jfrog/`),
  vendored into the image and auto-enabled when `JFROG_BASE_URL` + `JFROG_PAT`
  are present in `.env` (force off with `DISABLE_JFROG_MCP=1`). JFrog is
  API-only (no git transport), so it follows the Jira recipe: a two-value
  `JFROG_{BASE_URL,PAT}` pair with the access token presented as a Bearer token.
  Tools: `list_repositories`, `get_repository`, `search_artifacts`,
  `gavc_search`, `latest_version`, `get_item_info`, `get_file`, `list_builds`,
  `get_build`, and `aql_search` (powerful AQL queries — read-only `find` only;
  uses POST for the query body, with an enforced `.limit()` for large instances).
- **`jfrog-fetch`** skill driving the new tools for artifact/dependency and
  build-info lookups.
- Squid allowlist entry `squid/allowlist.d/40-jfrog.conf` for the Artifactory
  host (HTTPS/443).
- Read-only **Confluence MCP server** (`opencode/mcp-servers/confluence/`),
  vendored into the image and auto-enabled when `CONFLUENCE_BASE_URL` +
  `CONFLUENCE_PAT` are present in `.env` (force off with
  `DISABLE_CONFLUENCE_MCP=1`). API-only, following the Jira recipe: a two-value
  pair with the PAT presented as a Bearer token, appending `/rest/api` to the
  base URL. Tools: `get_page` (by id or space+title), `search` (CQL),
  `get_page_children`, `list_spaces`, `get_current_user`.
- **`confluence-fetch`** skill driving the new tools for wiki/documentation
  lookups (read a page, CQL search, browse a space's tree).
- Squid allowlist entry `squid/allowlist.d/50-confluence.conf` for the
  Confluence host, plus port **8090** added to `Safe_ports` and `SSL_ports` in
  `squid/squid.conf` (Confluence's default HTTP connector).

### Fixed
- **Plain-HTTP MCP targets on port 80** (e.g. JFrog/Bitbucket served over
  `http://…:80`) failed with a denied `CONNECT` (403). The MCP HTTP client
  (undici `ProxyAgent`) tunnels via `CONNECT` for every request — even plain
  HTTP — and squid only allows `CONNECT` to `SSL_ports`. Added `80` to
  `SSL_ports` in `squid/squid.conf` and documented that **every MCP target port
  must be in `SSL_ports`, not just `Safe_ports`** (with the `curl`-works-but-MCP-
  fails signature and the `--proxytunnel` repro) in `docs/MCP_SERVERS.md`.

### Changed
- `.env.example` gains a JFrog block and `DISABLE_JFROG_MCP`, plus a Confluence
  block and `DISABLE_CONFLUENCE_MCP`.
- `scripts/doctor.sh` now also verifies the GitLab, JFrog, and Confluence MCP
  wiring (GitLab was previously not checked).
- Docs (`README.md`, `docs/MCP_SERVERS.md`, `opencode/bundle/AGENTS.md`) updated
  to cover five MCP servers.
- `OPENCODE_VERSION` bumped `1.17.3` → `1.17.11` (build arg in
  `opencode/Dockerfile`, default in `docker-compose.yml`, and `.env.example`).
  Tested with the baked plugins before release.

## [0.0.5] — 2026-06-18

**Action required:** re-pull image + edit .env (new MCP credentials)

### Added
- Read-only **Bitbucket and Jira MCP servers**, vendored into the image and
  auto-enabled when their credentials are present in `.env`. A single PAT per
  service serves both git and the REST API.
- Read-only **GitLab integration** (MCP + git transport over HTTPS).
- Bundled skills for driving the Bitbucket and Jira MCPs.
- A global `AGENTS.md` house-rules file in the bundle.

### Changed
- `.env` literal loading instead of sourcing, so values with shell-special
  characters are read safely.

### Fixed
- MCP startup reads the canonical env var names in-process.
- Jira MCP authenticates the PAT as a Bearer token.

## [0.0.4] — 2026-06-12

**Action required:** re-pull image + review .env (`ENABLED_PLUGINS`)

### Changed
- `ENABLED_PLUGINS` is now the **single source of truth** for which plugins
  are active. Anything not listed is off.

### Added
- Plugin provenance: each baked-in plugin records its upstream repo and pinned
  version (see the table in `README.md`).

### Fixed
- Documented that the `opencode-workspace` plugin breaks Qwen — leave it
  disabled when working with Qwen.

## [0.0.3] — 2026-06-11

**Action required:** re-pull image + edit .env (`ENABLED_PLUGINS`) + rebuild squid

### Added
- A curated set of OpenCode **plugins baked into the image, off by default**,
  opt-in per developer via the new `ENABLED_PLUGINS` toggle in `.env`. No
  network needed at runtime.
- OpenCode version is now **pinned** at build time (`OPENCODE_VERSION`) so a
  rebuild can't silently change OpenCode and break baked plugins.

### Fixed
- Disabled plugins no longer linger in the persistent config volume.
- Squid config cleanup: removed the deprecated `dns_v4_first`, disabled the
  access log, and gated the per-developer `extra-allowlist.d/` include behind a
  committed placeholder so a fresh checkout builds.
- Added the SELinux `:z` relabel to the bind-mounted `/workspace` so enforcing
  hosts don't deny the container access.

### Docs
- Flagged the OpenCode web-UI / desktop-app `/workspace` bug with an upstream
  watch marker (TUI is unaffected and remains the recommended frontend).

## [0.0.2] — 2026-05-29

**Action required:** re-pull image

### Added
- A **socat publisher sidecar** so the OpenCode port reaches the host even on
  the internal-only network topology.
- `doctor.sh` now verifies OpenCode resolves the bundled config.

### Fixed
- Run OpenCode with `HOME=/home/dev` so the bundle is found; made skills
  loadable and added a primary agent.
- Squid `CONNECT` now works for non-443 TLS ports; hardened allowlist port
  guidance and ACL-name handling.
- Hardened `.env` parsing against inline comments breaking the published port.
- Permission policy: grant edit/bash/webfetch so headless agents can write,
  then deny webfetch in the shipped policy.
- LLM credentials read via `{file:}` indirection.

## [0.0.1] — 2026-05-11

**Action required:** full install (first release)

### Added
- Initial OpenCode Workplace image and three-network Docker Compose stack:
  OpenCode backend running non-root, all egress forced through a Squid proxy on
  a fixed allowlist.
- Starter agents, skills, and an MCP placeholder in the bundle.
- Per-developer user-layer overlay wired via `USER_LAYER_PATH`.
- Paste-and-run setup scripts and the initial docs set.
- Git safety gate: remote git operations blocked unless `ALLOW_REMOTE_GIT=1`.
