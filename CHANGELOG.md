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

_Nothing yet._

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
