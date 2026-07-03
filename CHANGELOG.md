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

## [Unreleased]

<!-- Action required: re-pull image + rebuild squid (docker compose build
     squid && docker compose up -d squid). If your .env still has an
     ENABLE_SESSION_LOGS line, it can be deleted — it is no longer read. -->

### Added
- **Machine-readable image manifest** (`/etc/opencode/manifest.json`), built
  from the checked-in `opencode/manifest.json` with `image_version`/
  `opencode_version` injected at build time. Lists every env key the
  container reads (with required/optional), the MCP servers it ships, and
  the baked plugins. This is what lets the launcher's drift check notice
  when the image grows a service the launcher doesn't know about yet
  (previously silent — see the launcher's own changelog for the check
  itself). Maintainers: add new env keys here in the same commit that adds
  them to the entrypoint/an MCP server (see MAINTAINERS.md).
- **In-image `CHANGELOG.md`** (`/etc/opencode/CHANGELOG.md`) — the running
  container now carries its own release notes, so a consumer (or the
  launcher, on a digest-change nudge) can print what changed without a
  separate fetch, e.g. `docker run --rm <img> sed -n '/^## \[0.0.7\]/,/^## /p'
  /etc/opencode/CHANGELOG.md`.
- **Local test harness** (`tests/`), mirroring the bats setup in
  `Opencode-Launcher`: `tests/run.sh` uses a system `bats` or fetches
  bats-core into `tests/.bats` (gitignored) on first run. `git-guard.bats`
  runs `opencode/git-guard` directly as a subprocess (blocked/allowed remote
  ops, the global-option bypass matrix, `remote add`/`set-url` gating,
  `ALLOW_REMOTE_GIT=1` reaching real git against a local bare repo, local
  commands behaving exactly like real git). `entrypoint.bats` unit-tests
  `trim`/`disabled_for`/`apply_policy_env` now that `entrypoint.sh` sources
  cleanly (see Changed, below) — and pins two real `disabled_for()` parser
  gaps it found along the way (see `tests/README.md` "Known limitations").
  `static.bats` checks cheap repo-wide invariants: `manifest.json` agrees
  with `.env.example`/the `mcp-servers/` directories/the Dockerfile's
  plugin builds/the entrypoint's `MCP_SERVICES` table; every
  `squid/allowlist.d/*.conf` line is a well-formed `acl allowed_dst
  dstdomain` line; `bash -n`/`node --check` across the repo; every tracked
  JSON file parses. 67 tests total. The MCP gate loop's per-service
  decision logic is deliberately NOT unit-tested — it needs the image's
  real `/opt/opencode` filesystem layout; forcing it into a stub would test
  the stub, not the logic (see `tests/README.md`).
- **`scripts/check.sh`** — the one-command local gate run before every
  release (wired into `MAINTAINERS.md` as step 0): `bash -n`, `shellcheck`
  (if present), JSON validation, `node --check` on the MCP servers, then
  the full `tests/` suite, with a PASS/FAIL/WARN/SKIP summary per section
  and a non-zero exit on any failure. Also runs the Docker-dependent checks
  (building both images, `squid -k parse`, the `MAINTAINERS.md` smoke
  test) when a Docker daemon is reachable, and lists them as manual
  reminders otherwise. This is the intended shape of the eventual CI job
  (no CI infra exists yet — see `docs/CROSS_REPO_REVIEW_2026-07.md` §4.3).

### Fixed
- **`git-guard` global-option bypass**: the guard only inspected `$1`, so
  `git -C <path> push`, `git -c k=v fetch`, `git --git-dir=… pull`, etc. sailed
  past it without triggering the `ALLOW_REMOTE_GIT` gate. It now scans past
  git's global options to find the real subcommand before deciding. Also adds
  `ls-remote` to the blocked set (purely remote, previously ungated).
- **`policy.yaml` values kept their literal quotes** when exported by the
  entrypoint (e.g. `OPENCODE_DISABLE_TELEMETRY` exported as the 3-character
  string `"1"`, and a quoted `NO_PROXY` overwrote the correct unquoted one
  compose set). The policy parser now strips one layer of surrounding quotes,
  same as the existing LLM-credential trimming.
- **Git credential helper matched hosts by suffix glob** (`*bitbucket.internal.example`),
  so a lookalike host like `evil-bitbucket.internal.example` would also match
  and receive real credentials. Matching is now exact-host.

### Changed
- **`entrypoint.sh` wraps its top-level boot flow in `main()`**, called only
  through a bottom source-guard (`[ "${BASH_SOURCE[0]}" = "${0}" ] && main
  "$@"`), the same pattern `Opencode-Launcher`'s `start.sh` uses — so the
  file's pure helpers can be unit-tested by sourcing it, without running
  PID-1 boot logic. This is a **pure code-motion refactor**: every
  top-level statement moved verbatim into `main()`; the five function
  definitions that were already there (`log`/`die`/`trim`/`disabled_for`/
  `symlink_bundle`) stayed top-level, untouched, so they're visible
  immediately after sourcing; `set -euo pipefail` stays at the very top of
  the file. The only deliberate logic change is that the former inline §7
  policy-parse loop is now the reusable `apply_policy_env FILE` function
  (body unchanged apart from the hardcoded path becoming the `$1`
  parameter), called from `main()` at the exact point the inline block used
  to run. Verified two ways: `git diff --color-moved=zebra HEAD~1 --
  opencode/entrypoint.sh` shows the body of `main()` as **moved** lines, not
  added/removed — 88 lines colored as moved vs. 34 add/12 del lines, all of
  which are the new `apply_policy_env`/`main()`/guard boilerplate; and
  `bash opencode/entrypoint.sh serve` as a non-root user with no env set
  fails identically before and after (`id: 'dev': no such user`, exit 1).
  **PID-1-critical — this ships in the runtime image's `ENTRYPOINT`. A live
  `docker build` + container boot smoke test is required before this lands
  in a release image** (Docker was not available in the environment this
  refactor was done in); see `MAINTAINERS.md` step 0 / `scripts/check.sh`'s
  docker-dependent reminders.
- **`NODE_MAJOR` bumped `20` → `22`** in `opencode/Dockerfile`. Node 20 reached
  end-of-life April 2026. The MCP servers are pure undici/zod (no native
  addons), so this is low-risk; validated with `node --check` on every
  server file under the new major.
- **Pinned the squid base image.** `squid/Dockerfile` built `FROM
  ubuntu/squid:latest`, a moving target under a system whose whole philosophy
  is deliberate pinning (cf. `OPENCODE_VERSION`). `ubuntu/squid` doesn't
  publish plain numbered tags, only `<squid>-<ubuntu>_beta`/`_edge` channel
  tags plus the `latest`/`edge` aliases — pinned to `ubuntu/squid:6.6-24.04_beta`
  by digest (what `latest` resolved to at pin time). See MAINTAINERS.md for
  the re-pin recipe.
- **`entrypoint.sh` §4b and `scripts/doctor.sh`'s MCP gating are now a table
  walk** instead of five hand-copied credential-gate blocks each. Both files
  share the same `"<service>:<needs_user>"` row format, so adding service #6
  is a one-row diff in each instead of editing five near-duplicate `if`
  blocks. Behavior (gating conditions, the generated `opencode.json` MCP
  entries, and every log/check line's wording) is unchanged — verified by
  diffing the old and new jq filter output byte-for-byte across ~19 env
  scenarios (all on/off/disabled/partial-credential combinations).
- **New shared MCP helper lib** (`opencode/mcp-servers/_lib/common.js`) for
  the plumbing all five first-party MCP servers re-implemented separately:
  the undici `ProxyAgent` dispatcher, env validation, auth-header
  construction (Bearer/Basic/PRIVATE-TOKEN), a `jsonGet` fetch helper, and
  MCP tool-error formatting. `_lib` carries its own `package.json` (depends
  on `undici`) since ESM resolution walks up from the importing file, not
  its caller. All five servers migrated onto it without changing tool
  names, descriptions, input schemas, or output text formatting.
- **Bitbucket's MCP server normalized onto `McpServer` + `server.tool(...)`**
  (`opencode/mcp-servers/bitbucket/index.js`), matching Jira/Confluence.
  (GitLab and JFrog also still use the older low-level `Server`/
  `ListToolsRequestSchema`/`CallToolRequestSchema` API — only Bitbucket's
  normalization was in scope this pass.) Every tool's name, description,
  input schema, and output format (`JSON.stringify(result, null, 2)`) is
  unchanged; verified by sending an MCP `initialize` + `tools/list`
  handshake to the running server and diffing the returned tool
  names/descriptions/schemas against the source.
- **MCP tool errors no longer include `err.stack`.** Every tool error
  response across all five servers now goes through the shared
  `toolError()` helper — message (and cause, where a tool already surfaced
  it) only. A raw Node stack trace in a tool result was pure token noise
  for the model and never explained *why* a request failed. Verified with
  a scratch server run that forces a fetch failure (bad hostname) and
  inspects the returned tool-error text.
- **Squid now logs denied requests** (unlisted destination, disallowed
  `CONNECT` port, unsafe port) to `docker compose logs squid`. Allowed
  traffic — including all LLM/conversation data — is still never logged, so
  the no-retention stance is unchanged; this only makes self-service
  allowlist debugging possible (`docs/TROUBLESHOOTING.md` previously pointed
  at a log line that could never exist).
- **Removed passwordless `sudo`** for the `dev` user (`usermod`/`groupmod`/`chown`)
  and dropped the `sudo` package from the image entirely. Nothing legitimate
  used it — the UID remap runs in the entrypoint as root, before dropping to
  `dev` via `gosu` — and it allowed re-owning the host workspace bind mount
  from inside the container.
- **`scripts/doctor.sh` treats Bitbucket credentials as optional**, matching
  `.env.example` and the launcher: `BITBUCKET_USER`/`BITBUCKET_PAT` unset now
  prints a warning instead of failing the check.

### Removed
- **`ENABLE_SESSION_LOGS` knob.** It never actually worked: disabling it tried
  to mount a tmpfs over the state directory, which requires `CAP_SYS_ADMIN`
  that compose never grants, so the mount always silently failed and session
  logs were always persisted regardless of the setting. Removed the dead
  code path, the `.env.example` entry, and the docs that described the
  (non-functional) toggle. An old `.env` that still sets it is harmlessly
  ignored.

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
