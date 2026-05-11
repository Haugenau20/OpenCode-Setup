# Implementation Plan

The scaffold on `main` lays out files but has not been built or run. This
plan turns the scaffold into a working, shippable image. Each phase has a
concrete deliverable and an explicit success criterion. Phases are ordered
so each one builds on the previous; do not skip ahead.

Branch for all work: `claude/implementation` (this branch). PR into `main`
when each phase is green, or at the end — your call. Smaller PRs are
easier to review.

---

## Phase 0 — Verify upstream facts

Before writing code that depends on opencode internals, confirm three
things that the scaffold assumes:

- [ ] The npm package name is `opencode-ai` (the Dockerfile uses this).
      If it's something else, change `opencode/Dockerfile`.
- [ ] The CLI accepts `--hostname` and `--port` on `opencode serve`
      (the entrypoint passes these).
- [ ] The provider schema in `opencode.json.tmpl` matches the current
      opencode config schema for OpenAI-compatible providers
      (`@ai-sdk/openai-compatible`).

**Deliverable:** small note appended to `docs/ARCHITECTURE.md` recording
the verified opencode version and provider schema reference URL.

**Done when:** `npm view opencode-ai` returns metadata and the resulting
image runs `opencode --version` without error.

---

## Phase 1 — Build & boot

Get the image to build and start the opencode server cleanly with an empty
`ca/` directory and a minimal `.env`.

### 1.1 Build both images locally
- [ ] `cp .env.example .env` and fill in mock values (LLM_API_BASE can be
      a placeholder; LLM_API_KEY=test).
- [ ] `docker compose build`
- [ ] Resolve any apt / npm / `npm install -g opencode-ai` failures.

### 1.2 Bring the stack up
- [ ] `docker compose up -d`
- [ ] `docker compose logs opencode` shows the entrypoint walking through
      its eight steps without errors.
- [ ] `curl -sI http://localhost:4096` returns an HTTP response (any code;
      we just need the server alive).

### 1.3 UID/GID remap sanity
- [ ] Inside the container, `id dev` reports the UID/GID from `.env`.
- [ ] A bind-mounted file under `/workspace` is owned by `dev`, not root.

**Done when:** stack comes up cleanly twice in a row (`down` → `up -d`)
and the web UI port responds.

---

## Phase 2 — Frontends

Make sure all three frontends actually attach.

### 2.1 Web UI
- [ ] Open `http://localhost:4096` in a host browser. The opencode UI
      loads.
- [ ] Starting a chat from the web UI creates a session visible via
      `docker exec opencode-default ls ~/.local/share/opencode/`.

### 2.2 TUI
- [ ] `./scripts/opencode` attaches a TUI to the running container.
- [ ] The TUI session shares state with the web UI (same session list).

### 2.3 Desktop app (host-side)
- [ ] Install the desktop app from opencode.ai/download on a dev machine.
- [ ] Point it at `http://localhost:4096`. Same shared state.

**Done when:** all three frontends can open the same session.

---

## Phase 3 — LLM through Squid

Wire up real LLM traffic and prove nothing else can get out.

### 3.1 Replace allowlist placeholders
- [ ] Edit `squid/allowlist.d/00-llm.conf` with the real LLM hostname.
- [ ] Edit `10-bitbucket.conf` and `20-jira.conf` with the real internal
      hosts.
- [ ] `docker compose build squid && docker compose up -d`.

### 3.2 Drop the corp CA in
- [ ] Place the corporate root cert at `ca/corp-root.crt`.
- [ ] Rebuild both images (`docker compose build`).
- [ ] Inside the container, `curl https://<llm-host>/` returns a valid TLS
      handshake (no `x509: unknown authority`).

### 3.3 Egress lockdown verification
- [ ] From the opencode container, `curl https://example.com` **fails**
      (denied by squid).
- [ ] From the opencode container, `curl --noproxy '*' https://1.1.1.1`
      **fails** (no route — squid is the only path out).
- [ ] `curl` against the LLM host **succeeds**.

### 3.4 Round-trip
- [ ] Send a prompt via the TUI. A real model response comes back.
- [ ] `docker compose logs squid` shows the CONNECT to the LLM host.

**Done when:** opencode talks to the LLM and `example.com` is refused.

---

## Phase 4 — Safety gates & persistence

### 4.1 git-guard
- [ ] With `ALLOW_REMOTE_GIT=0`, inside the container:
      - [ ] `git push origin main` is refused with the policy message.
      - [ ] `git status`, `git commit`, `git log` work normally.
- [ ] Flip `ALLOW_REMOTE_GIT=1`, `docker compose up -d`, push succeeds
      (against a test repo in the company Bitbucket).

### 4.2 Bitbucket credential helper
- [ ] `git ls-remote https://bitbucket.internal.example/scm/proj/repo.git`
      from the container authenticates via the `BITBUCKET_PAT` env var.
- [ ] The PAT does **not** appear in `/home/dev/.gitconfig` or
      `~/.git-credentials` inside the container.

### 4.3 Session persistence
- [ ] Start a conversation in the TUI.
- [ ] `docker compose down && docker compose up -d`.
- [ ] The conversation is still listed and resumable.

### 4.4 Disable session logs
- [ ] Set `ENABLE_SESSION_LOGS=0`, recreate.
- [ ] Inside the container, `mount | grep opencode` shows tmpfs over the
      state dir (or, if the mount failed due to caps, the entrypoint
      logged a warning — non-blocking).
- [ ] After restart, no history is retained.

**Done when:** all four sub-checks pass.

---

## Phase 5 — Config layering

### 5.1 Wire `USER_LAYER_PATH`
- [ ] **Gap to fix:** `.env.example` mentions `USER_LAYER_PATH` but
      `docker-compose.yml` does not branch on it. Either:
      - add a compose `extends:`-style overlay, or
      - introduce a small wrapper in `scripts/opencode` that picks the
        right compose file, or
      - just document that setting `USER_LAYER_PATH` requires hand-editing
        the compose file (least friction, worst UX).
- [ ] Recommended: a `docker-compose.user-layer.yml` overlay that swaps
      the named volume for the bind mount. `scripts/opencode` picks it up
      automatically when `USER_LAYER_PATH` is set.

### 5.2 Bundle merging
- [ ] Drop a trivial agent into `opencode/bundle/agents/hello.md` and
      rebuild.
- [ ] After `up -d`, the agent appears in `~/.config/opencode/agents/` as
      a symlink to the bundle.
- [ ] The opencode UI/TUI lists it.

### 5.3 Disable + shadow
- [ ] Add `hello` to `disabled.yaml` under `agents:`. After restart, the
      symlink is absent; the agent disappears from opencode.
- [ ] Remove from `disabled.yaml`. Place a custom `hello.md` in the user
      layer. After restart, the user's file wins (no symlink).

**Done when:** a developer can add, override, and disable bundled items
without rebuilding the image.

---

## Phase 6 — Multi-stack & UX polish

### 6.1 Two stacks at once
- [ ] `./scripts/new-project.sh second ~/code/second 4097` produces a
      sibling directory with a unique slug and port.
- [ ] Both stacks run simultaneously. No volume, container, or port
      collisions.

### 6.2 doctor.sh real-world coverage
- [ ] Run `./scripts/doctor.sh` against a healthy stack — all green.
- [ ] Break the stack (wrong allowlist) — doctor reports the right
      failure with a useful message.

### 6.3 Prompt indicator
- [ ] Shell prompt inside the container shows `[oc:<slug>|git:ro]` and
      flips to `git:rw` when `ALLOW_REMOTE_GIT=1`.

**Done when:** a fresh dev can `cp .env.example .env`, edit four values,
`up -d`, and use opencode end-to-end without reading the README.

---

## Phase 7 — Ship starter content

### 7.1 First-party bundle
- [ ] Add 1–2 starter agents covering common workflows
      (e.g. `bitbucket-pr-reviewer`, `commit-message-writer`).
- [ ] Add 1–2 skills documenting house style (commit conventions, branch
      naming).
- [ ] Add a `/sync-jira` slash command shell, gated behind a flag while
      the JIRA integration is still being designed.

### 7.2 MCP placeholder
- [ ] `opencode/bundle/mcp/rag.yaml` ships disabled-by-default (commented
      `enabled: false`). Updated when the RAG service has a real URL.

**Done when:** the image ships with at least two useful agents and the
RAG slot is wired up but inactive.

---

## Phase 8 — Distribution

### 8.1 Local push to Artifactory (manual)
- [ ] `docker tag` and `docker push` both images to
      `artifactory.internal.example/opencode-workplace{,-squid}:staging`.
- [ ] On a clean machine, `docker compose -f docker-compose.yml -f
      docker-compose.staging.yml pull && up -d` works.

### 8.2 Promote to prod
- [ ] After smoke test passes, retag staging → prod and push.

### 8.3 Versioning
- [ ] Decide the version-tagging scheme (date-based `2026.05.11` or
      semver `0.1.0`). Update `MAINTAINERS.md` accordingly.

**Done when:** a developer on a fresh machine can install only docker
+ this repo, `pull`, and run.

---

## Deferred (not in this implementation pass)

These are explicitly out of scope until someone says otherwise:

- **TeamCity pipeline.** Manual builds for now. Phase 8 stays manual.
- **`/report-bug` slash command.** Sketched in design; build when there's
  a JIRA project to post to and a redaction policy.
- **Real RAG MCP wiring.** The bundle has a placeholder file. Wire the
  real URL when the service exists.
- **Desktop-app installer mirroring.** Devs install from
  opencode.ai/download themselves. If offline install becomes a
  requirement, mirror the installer in Artifactory.

---

## How to use this document

- Treat each phase as one PR (or one logical block of commits) into
  `main`. Update the checklist as items go green.
- If a phase reveals a design problem, stop and update
  `docs/ARCHITECTURE.md` first — the design doc is the source of truth.
- Anything new that doesn't fit a phase gets added to "Deferred" with a
  one-line justification.
