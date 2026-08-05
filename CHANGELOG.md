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

**Action required:** re-pull image + edit .env (new opt-in switches:
`ALLOW_CONFLUENCE_WRITE`, `ALLOW_GITLAB_WRITE`, `GIT_REMOTE_ALLOWLIST`,
`OPENCODE_INTERNAL_PORT`, plus the Symphony keys — every one defaults to
today's behaviour)

### Added
- **Writing to Confluence**, behind a new `ALLOW_CONFLUENCE_WRITE` gate in
  `.env` — **default `0`**, and (like every other switch here) only the exact
  value `1` turns it on. With it set, the Confluence MCP grows four tools:
  `create_page` (new page in a space, optionally under a `parentId`),
  `update_page` (replace body and/or title), `append_to_page` (add to the end,
  keeping existing content) and `add_comment`. This is the first write plane in
  any of the six MCP servers; it is deliberately shaped after `ALLOW_REMOTE_GIT`
  — reading a wiki is recoverable, writing to one is visible to everyone.
- Bodies may be given as Confluence **storage format** (XHTML, the default) or
  as **wiki markup** (`format="wiki"`, e.g. `h1. Title`), converted by
  Confluence's own `/rest/api/contentbody/convert/storage` endpoint rather than
  by a hand-rolled converter here. Markdown is not a Confluence representation
  and is not accepted.
- `get_page` gained `format="storage"`, returning the raw markup instead of the
  lossy plain-text rendering — needed to read a page before an `update_page`
  that preserves existing content.
- **`confluence-write`** skill covering the write workflow (choosing where a
  page goes, checking for an existing page first, storage-vs-wiki, a wiki-markup
  cheat sheet, always passing a `versionComment`).
- `.requires` files gained an **`env=NAME=value`** gate alongside `plugin=` and
  `mcp=`, so a skill can be linked in only when a switch is on. `confluence-write`
  uses `mcp=confluence` + `env=ALLOW_CONFLUENCE_WRITE=1`, meaning a default
  install never even tells the agent about tools it doesn't have. Malformed and
  unknown keys still fail closed.
- `jsonSend()` in `mcp-servers/_lib/common.js` — the POST/PUT counterpart to
  `jsonGet()`. It additionally returns the server's own error text on a non-2xx:
  a failed read is diagnosable from its status code, a rejected write ("a page
  with this title already exists") is not.
- Boot log now reports which side of the gate the container came up on:
  `mcp ro: confluence` / `mcp rw: confluence`.

- **Symphony: opt-in unattended orchestration from a folder queue.** A separate
  image and compose overlay (`docker-compose.symphony.yml`) that watches a
  `symphony-queue/` directory tree and runs an OpenCode agent per work item
  until it is ready for a human. The tracker is the filesystem: the directory an
  item's markdown file sits in *is* its state (`todo/`, `in-progress/`,
  `review/`, `done/`, `failed/`, `cancelled/`), and claiming is a `rename(2)`,
  so the move is the lock. `ls` is the dashboard; there is no UI and no
  database. The orchestrator itself is
  [`Haugenau20/symphony-queue`](https://github.com/Haugenau20/symphony-queue),
  vendored at a pinned `SYMPHONY_REF` exactly the way the opt-in plugins are.

  The symphony container sits on `oc_internal` only: **no egress, no
  credentials, no git remote of its own.** It talks to the opencode server and
  moves files; every credential-bearing operation happens in the opencode
  container, where git-guard, squid and the credential helper already apply.

  Nothing in the base stack changes while the overlay is absent. New files:
  `symphony/Dockerfile`, `symphony/entrypoint.sh`,
  `symphony/WORKFLOW.md.example`, `docker-compose.symphony.yml`,
  `docker-compose.symphony-dev.yml`, `docs/SYMPHONY.md`.

- **`GIT_REMOTE_ALLOWLIST`: a destination gate for remote git.** `ALLOW_REMOTE_GIT`
  is binary — once it is 1, every remote is reachable, which is fine for a human
  and wrong for an unattended agent. The new variable narrows *where* remote git
  may go: whitespace- or comma-separated `host/path` prefixes, matched on a
  path-segment boundary (so `…/sandbox` is not satisfied by `…/sandbox-evil`).
  It resolves named remotes through `git remote get-url`, normalizes scp-style
  `git@host:path`, ignores ports and userinfo, and honours `-C` / `--git-dir`
  so the remote is read from the repo the command will actually act on. Empty or
  unset means no restriction, so existing setups are untouched. 21 new bats
  cases in `tests/git-guard.bats`.

  This is **defence in depth, not a security boundary** — an agent with a bash
  tool can call `/usr/bin/git` directly, past the PATH shim. It turns a mistake
  into a legible local error. The boundary is the credential: a GitLab **project
  access token** (or a group one, if symphony must span repos), enforced
  server-side. `docs/SYMPHONY.md` says this at length and it is the part to read
  before running anything unattended.

- **GitLab Issues as a second symphony tracker.** `tracker.kind: gitlab` in
  `WORKFLOW.md` runs work items as GitLab issues instead of files, with state
  held in a `symphony::<state>` label. Both trackers ship; the file queue stays
  the zero-setup option (no token, no network) and remains what the test suite
  exercises. New `symphony/WORKFLOW.gitlab.md.example`.

  Every transition rewrites the **whole** label set in one request rather than
  add-then-remove, so there is no window where an issue wears two states — and
  no dependence on scoped labels, which are Premium. Behaviour is identical on
  Free. Blocking issue links are Premium too, so blockers degrade to "none"
  there rather than erroring.

  What it costs: the file queue's claim is a `rename(2)` and cannot double-
  claim; the Issues API has no compare-and-swap, so two orchestrators against
  one project can both dispatch an issue. One orchestrator — the supported
  deployment — is unaffected.

- **Two tokens for the GitLab tracker** (`SYMPHONY_GITLAB_TOKEN` +
  `SYMPHONY_HTTP_PROXY`). Symphony gets a **project** access token with the
  **Reporter** role: it reads and writes issues on one project and cannot push
  code. The agent keeps a separate Developer token for the repository. Neither
  can do the other's job, so a compromised orchestrator can vandalize issue text
  and nothing else. Note `api` is full API access for that project — there is no
  issues-only scope, and it is the *role* that constrains it.

  This does cost symphony its "no credentials, no egress" posture, but only on
  the GitLab tracker: it joins `oc_proxy` and reaches GitLab through squid,
  which was already allowlisted. On `file_queue` it still holds nothing.

- **GitLab MCP: issues, pipelines, and an opt-in write surface.** New read
  tools `list_issues`, `get_issue`, `get_issue_notes` and `get_pipelines` — the
  server previously had no issue support at all, which the GitLab tracker needs.

  New write tools, **off by default** behind `ALLOW_GITLAB_WRITE=1`:
  `create_merge_request`, `update_merge_request`, `create_mr_note`,
  `create_issue`, `create_issue_note`, `update_issue_note`. Optionally narrowed
  to specific projects with `GITLAB_WRITE_PROJECTS` (whitespace/comma-separated,
  prefix-matched on a path-segment boundary — the same rule
  `GIT_REMOTE_ALLOWLIST` uses). Gated twice: the tools are not listed when the
  switch is off, **and** every write handler re-checks, because a client can
  call a tool it was never offered.

  Deliberately absent even at `=1`: anything that sets issue labels, closes or
  reopens an issue, or merges an MR. In the symphony workflow the `symphony::`
  label *is* the workflow state and the orchestrator owns every transition — an
  agent able to relabel its own issue could mark its work reviewed or feed
  itself work forever. `create_issue` refuses labels in that namespace
  (`GITLAB_QUEUE_LABEL_PREFIX`, default `symphony`), so a follow-up arrives
  unlabelled and a human admits it to the queue.

  Gating logic lives in a new dependency-free `opencode/mcp-servers/_lib/write_gate.js`
  so it is unit-testable without any server's `node_modules`, and is
  service-agnostic for whenever a second server needs it. 24 unit tests plus 5
  structural tests that fail if a future write tool skips the gate.

  This closes the "no agent-authored workpad on GitLab" limitation noted when
  the tracker landed: the agent can now keep one running comment on its issue
  via `get_issue_notes` + `update_issue_note`.

- **`OPENCODE_EXTRA_ALLOWED_DIRS: /workspaces/**` on the symphony overlay.**
  opencode gates any tool touching a path outside the `/workspace` project root
  behind `permission.external_directory`, which defaults to `ask`. Symphony's
  per-item workspaces live outside it, and unattended means nobody is there to
  answer — so without this the first file operation of every run would block
  forever. Reuses the generic hook the launcher already uses for `--also`
  mounts, with the overlay playing the launcher's role.

- **`scripts/symphony`**, the host-side launcher for the overlay and the
  counterpart to `scripts/opencode`. Composes the right `-f` flags (including
  the user-layer and symphony-dev overlays when those are configured) and adds
  `check` / `up` / `logs` / `status` / `watch` / `add` / `stop` / `down` /
  `build`.

  Its preflight refuses to start on a missing `WORKFLOW.md`, a GitLab tracker
  with no token or no egress, or a workspaces mount that is your real repo; and
  warns on one token shared between symphony and the agent, remote git enabled
  with no `GIT_REMOTE_ALLOWLIST`, writes enabled with no
  `GITLAB_WRITE_PROJECTS`, and concurrency above one. `add` writes queue items
  with front matter the tracker accepts, so there is nothing to hand-format. 16
  bats cases.

### Notes
- **Deleting pages is not implemented**, gate or no gate. Edits live in
  Confluence's version history and are one click from being undone; deletions
  are not, so they stay a browser action.
- Writes act as the `CONFLUENCE_PAT` owner and appear under that name in the
  page history. A 403 on write with a working read means that account lacks
  add/edit rights in the target space.
- Existing installs are unaffected until they opt in: with the variable absent
  the server registers exactly the five read tools it always had.

### Changed
- `opencode/manifest.json` gains `ALLOW_GITLAB_WRITE`, `GITLAB_WRITE_PROJECTS`,
  `GITLAB_QUEUE_LABEL_PREFIX` and the previously-missed `GIT_REMOTE_ALLOWLIST`.
- The `gitlab-fetch` skill documents the issue tools, the write surface, the
  one-comment workpad pattern, and what is deliberately impossible.
- **`OPENCODE_INTERNAL_PORT` is now a real variable** (`.env`, default `4096`)
  and the four places that hard-coded `4096` derive from it: the oc-publish
  socat forwarder, the container side of the published port, the symphony
  overlay's `SYMPHONY_OPENCODE_URL` and symphony's entrypoint fallback. It is
  deliberately **not** `OPENCODE_PORT` — that is the *host* port, and the two
  are decoupled so several stacks can differ on the host while all of them stay
  on 4096 inside. With the variable absent from `.env`, `docker compose config`
  renders exactly as before.

### Fixed
- **The symphony workflow prompts never told the agent to clone anything.** The
  `after_create` hook is empty on purpose — a clone there would force a
  repository credential into the symphony container, which holds only the
  Reporter token — and the hook's comment said the agent clones as its first
  step instead. Nothing said so to the agent, which got an empty workspace, no
  code, and no instruction to fetch any. Both `WORKFLOW.*.example` files now
  carry a "First: clone the project" section; the URL comes from that file
  (trusted config, mounted read-only) and the prompt is explicit that a
  repository URL found in issue or item text is an attack, not an instruction.
- **`stall_timeout_ms` is a wall-clock run timeout, not a stall detector**, at
  the currently pinned `SYMPHONY_REF`: nothing updates the reference timestamp
  while the agent works, so any run outliving the value is killed however much
  progress it is making. At the upstream 300000 (5 min) that makes "clone a
  repo and implement something" impossible. The GitLab example ships 1800000,
  both examples say what the number actually measures, and `docs/SYMPHONY.md`
  explains how to tell whether a newer symphony-queue has made it a real
  detector.
- **`./scripts/symphony check` cross-checks the two allowlists.**
  `GIT_REMOTE_ALLOWLIST` (git plane, git-guard) and `GITLAB_WRITE_PROJECTS`
  (API plane, MCP write gate) express nearly the same intent in two formats and
  are enforced by different processes, so nothing made them agree — setting one
  and forgetting the other gives an agent that can push a branch but not open
  the MR, or the reverse. The preflight is the one place that sees both. It
  also checks the tracker's own project, which is the destination the workflow
  explicitly tells the agent to clone. Same normalization and segment-boundary
  prefix rule both gates already use, so `mygroup` cannot be satisfied by
  `mygroup-evil`. 10 new bats cases (176 total).
- **The symphony image did not set `NODE_EXTRA_CA_CERTS`**, so an on-prem GitLab
  behind a private CA failed TLS from Node while `curl` in the same container
  worked. `update-ca-certificates` populates the *system* store and Node ships
  its own bundle; `opencode/Dockerfile` has bridged that for a while, and the
  symphony image — written as "no egress, no credentials" — never did.
- **The GitLab tracker presented a file queue that was not its own.** The six
  state directories are the `file_queue` tracker's storage; under
  `tracker.kind: gitlab` they hold nothing, but the launcher and the container
  entrypoint created them, `status` counted them, and `add` wrote into them. A
  leftover item from an earlier file-queue run therefore printed as `todo 1`
  for a queue symphony was not reading. Now nothing creates them under the
  gitlab tracker, `status` names the project and links the issue board, and
  `add` refuses with the label to use instead. `symphony-workspaces/` is still
  created either way — the agent gets one per item whichever tracker produced
  it. 6 more bats cases (182 total).

- **The GitLab workflow example now sets `agent.continuation_guidance`** and
  documents what `max_turns` actually buys. Turn 1 is the task prompt and turns
  2..N are continuations; when they run out the run ends and the item goes to
  `symphony::review` **whether or not anything was produced**, because running
  out of turns is a clean exit. The continuation prompt is the lever that stops
  a non-frontier model polishing until the turns are gone, so the example
  spends it on "you are not done until the merge request exists" and on what to
  do with one turn left. (`continuation_guidance` requires a `SYMPHONY_REF`
  carrying the upstream change; older builds ignore the key.)

### Notes
- **Found by the first live GitLab run** (previously everything here was tested
  against mocks only): the biggest failure was in `symphony-queue` rather than
  this repo — its GitLab tracker called Node's global `fetch`, which is undici,
  and **undici ignores `HTTP_PROXY`/`HTTPS_PROXY`**. `SYMPHONY_HTTP_PROXY` was
  therefore set, exported, documented as symphony's egress, and read by nobody;
  every API call went out direct from `internal: true` networks and died as
  `TypeError: fetch failed`. Fixed upstream by using undici's `ProxyAgent`, the
  same way every MCP server in this image already does. If you are pinned to a
  `SYMPHONY_REF` older than that fix, this is the failure you will see.

## [0.2.0] — 2026-07-15

**Action required:** re-pull image + rebuild squid + edit .env (new MCP credentials)

### Added
- Read-only **M-Files MCP server** (`opencode/mcp-servers/mfiles/`), vendored
  into the image and auto-enabled when `MFILES_BASE_URL` + `MFILES_PAT` are
  present in `.env` (force off with `DISABLE_MFILES_MCP=1`). M-Files is API-only
  (no git transport), so it follows the Jira/JFrog/Confluence recipe — a
  two-value `MFILES_{BASE_URL,PAT}` pair — but is the **first server to use a
  custom `X-Authentication` header** for the PAT (not Authorization/Bearer, not
  Basic, no username); the server appends `/REST` to the base URL. Tools:
  `list_object_types`, `list_classes`, `search_objects`, `get_object`,
  `get_object_properties`, `get_file_content`.
- **`mfiles-fetch`** skill driving the new tools for document-management (DMS)
  lookups (discover object types, search, fetch an object with its properties
  and files, download file content).
- New `xAuthenticationAuth()` builder in `opencode/mcp-servers/_lib/common.js`.
- Squid allowlist entry `squid/allowlist.d/60-mfiles.conf` for the M-Files host
  (HTTPS/443 — non-standard ports go in `squid.conf` `SSL_ports`).
- **"Getting an M-Files authentication token"** section in `docs/MCP_SERVERS.md`
  covering how to mint `MFILES_PAT` — unlike the other services, the
  `X-Authentication` value is a session token you obtain by POSTing vault
  credentials to `/REST/server/authenticationtokens` (incl. reading the vault
  GUID from M-Files Desktop Settings, the `Domain`/`Expiration`/`ReadOnly`
  fields, token-expiry `401`/`403` symptoms, and doing it through the
  container's Squid proxy). `.env.example` points at it.

### Changed
- `.env.example` gains an M-Files block and `DISABLE_MFILES_MCP`.
- `scripts/doctor.sh` `MCP_SERVICES` table adds `mfiles:0`, so the health check
  verifies the M-Files MCP wiring too.
- Docs (`docs/MCP_SERVERS.md`, `opencode/bundle/AGENTS.md`) and
  `opencode/manifest.json` updated to cover six MCP servers.
- **New top-level `VERSION` file** holds the current release number as the
  single source of truth. A new **`scripts/release.sh`** reads it and does the
  whole build → tag → push (opencode + squid images) in one command, passing the
  version as the `IMAGE_VERSION` build arg so the image tag, OCI label, and
  `/etc/opencode/manifest.json` can't drift. Push is gated behind `--push` (with
  a confirmation prompt) and `--latest` moves the floating tag; `MAINTAINERS.md`
  documents the new flow. (Consumers pin with `IMAGE_TAG` as before — no consumer
  action.)
- **`pty-sessions` skill** clarified: `pty_spawn`'s `command` must be something
  that keeps the terminal open (e.g. `bash`, not `echo hello`, which exits
  immediately), and driving a session via `pty_write` requires a trailing
  newline (`\n`) to act as pressing Enter.

## [0.1.0] — 2026-07-10

**Action required:** re-pull image + recreate the stack (the `NO_PROXY`, Squid
`append_domain`, and theme changes ship in the images / `docker-compose.yml`),
then review .env. The default theme name changed from `corp` to `corp-dark` —
update any `tui.json` `theme` field or `disabled.yaml` `themes:` entry that
pointed at `corp` to `corp-dark` or `corp-light`. `BITBUCKET_USER` is now
optional for the MCP (Bearer) but still required for git-over-HTTPS; consider
pointing `BITBUCKET_BASE_URL` at your canonical HTTPS endpoint and setting the
new optional `BITBUCKET_LEGACY_URL`.

### Added
- **`BITBUCKET_LEGACY_URL` (optional)** — when set to a legacy Bitbucket URL that
  redirects to `BITBUCKET_BASE_URL` (typically the plain-HTTP connector on
  `:7990`), the entrypoint bakes a git `url.<canonical>.insteadOf <legacy>`
  rewrite into the container `.gitconfig`. A repo remote still pointing at the
  legacy URL is transparently upgraded before git connects, so the server's
  HTTP→HTTPS redirect no longer surfaces as an interactive
  `Username for 'https://…:8443'` prompt. No-op when unset.
- **Squid `append_domain`** — `squid.conf` now appends the internal domain
  (`.corp.local`; set it to yours) to bare hostnames, so clients can reach
  internal services by short name (e.g. `mybitbucket`) instead of `503`-ing at
  the proxy. Squid ignores the resolv.conf `search` list (it uses its own
  resolver), so this lives in `squid.conf`, not a compose `dns_search`. Only
  dotless names are affected; FQDNs, the LLM endpoint, and the egress allowlist
  are unchanged (the allowlist matches the requested name, before DNS).

### Changed
- **Split the bundled `corp` theme into separate `corp-dark` and `corp-light`
  theme files** (`opencode/bundle/themes/corp-dark.json` /
  `corp-light.json`), replacing the single `corp.json` that encoded both
  palettes via per-key `{dark, light}` objects. Each file is now a flat,
  self-contained theme with its own `defs`/`theme` blocks, so either can be
  selected directly by name. `tui.json`'s default `theme` is now `corp-dark`
  (previously `corp`).
- **Bitbucket MCP now authenticates with a Bearer PAT** (Bitbucket Data Center
  HTTP access token) instead of HTTP Basic, matching Jira/JFrog/Confluence.
  `BITBUCKET_USER` is no longer required to enable the MCP — it is optional and
  consumed only by the git credential helper for git-over-HTTPS. Existing setups
  with the full trio keep working unchanged.
- **`.env.example` now defaults `BITBUCKET_BASE_URL` to HTTPS** and the docs
  steer toward the canonical HTTPS endpoint; the plain-HTTP connector still works
  for the REST API but is the source of the redirect prompt above.
- **Git credential helper now answers for the bare hostname too.** It matches
  both the FQDN (`mybitbucket.corp.local`) and its short first-label form
  (`mybitbucket`), so a remote using the short name (resolved by Squid's
  `append_domain`) authenticates instead of falling back to an interactive
  `Username for …` prompt. Still requires `BITBUCKET_USER`/`GITLAB_USER` —
  git-over-HTTPS is HTTP Basic and needs a username.

### Fixed
- **Removed `.local` from `NO_PROXY`** (`docker-compose.yml` + `policy.yaml`).
  It matched internal FQDNs like `bitbucket.corp.local`, forcing `git`/`curl` to
  bypass squid and connect directly — which fails, since the container has no
  direct egress (`could not resolve host` / `CONNECT tunnel failed`). The MCP
  masked this by using undici's `ProxyAgent`, which ignores `NO_PROXY`. With
  `.local` gone, all clients route corp `*.local` hosts through squid, so
  git-over-HTTPS (and manual curl) reach Bitbucket like the MCP already does.

### Docs
- **TROUBLESHOOTING.md** — new entries for the per-user
  `Username for 'https://…:8443'` git prompt (a Bitbucket base-URL redirect
  surfaced by the repo's git remote, not `BITBUCKET_BASE_URL`) and for the
  "could not resolve host / CONNECT tunnel failed" `NO_PROXY` bypass, each with
  confirm/fix steps.

## [0.0.8] — 2026-07-09

**Action required:** re-pull image. Opt in to `opencode-pty` via
`ENABLED_PLUGINS`; if you want its web viewer, also update your launcher/compose
(the `oc-publish` sidecar now publishes the derived viewer port too — see below).

### Added
- **`opencode-pty` plugin** (opt-in via `ENABLED_PLUGINS`, off by default) —
  interactive PTY management: model-callable tools (`pty_spawn`, `pty_write`,
  `pty_read`, `pty_list`, `pty_kill`) for driving background processes in real
  pseudo-terminals, plus a live web viewer started from the TUI via
  `/pty-open-background-spy`. The published npm package already ships a fully
  built `dist/` (plugin + a self-contained Vite-bundled web UI) and its
  `bun-pty` dependency ships a prebuilt native library loaded via Bun FFI, so
  nothing is compiled at image-build time — only `npm install --omit=dev` and
  a straight vendor of `node_modules`, same offline-ready shape as the other
  baked plugins.
- **The `opencode-pty` web viewer is reachable from the host.** The plugin
  binds its server to `PTY_WEB_HOSTNAME` (fixed to `0.0.0.0` in
  `docker-compose.yml`, since the plugin's own default — `::1` — is
  loopback-only) on a port `docker-compose.yml` derives from `OPENCODE_PORT` by
  prepending a `1` (main `4096` → viewer `14096`), so the viewer sits clear of
  the `4096+N` range a multi-instance launcher uses and is unique per instance
  without any per-instance config. The `oc-publish` sidecar now runs two `socat`
  listeners instead of one, forwarding that derived port to the container just
  like it already does for `OPENCODE_PORT`. No squid/allowlist
  changes — the viewer is inbound-only, served entirely inside the compose
  network.
- **`pty-sessions` skill** — a bundled skill that teaches the agent when and how
  to use the `opencode-pty` tools (spawn/read/write background & interactive
  processes) rather than the blocking one-shot `bash` tool. It is **gated on the
  plugin**: present only when `opencode-pty` is in `ENABLED_PLUGINS`.
- **Conditional bundle content (`.requires` gate).** A bundled skill can declare
  a provider dependency in a `.requires` file next to its `SKILL.md`
  (`plugin=<name>` or `mcp=<name>`); the entrypoint links it only when that
  provider is active, and retracts it on a later boot if the provider is turned
  off. See [`docs/ADDING_SKILLS.md`](docs/ADDING_SKILLS.md).

### Changed
- **The `*-fetch` skills now appear only when their service is up.** Each of
  `bitbucket-fetch` / `jira-fetch` / `gitlab-fetch` / `jfrog-fetch` /
  `confluence-fetch` carries an `mcp=<service>` gate, so a service that has no
  credentials in `.env` (or is force-disabled via `DISABLE_<SVC>_MCP=1`) no
  longer surfaces a companion skill for a server that isn't running. The gate
  reuses the exact predicate that decides whether the MCP server is wired into
  the config, so the two can never disagree.
- **Bumped the bundled OpenCode CLI to `1.17.15`** (from `1.17.11`). The baked
  plugins were re-tested against it with no apparent errors.

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
