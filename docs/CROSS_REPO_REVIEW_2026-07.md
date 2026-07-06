# Cross-repo review: OpenCode-Setup + Opencode-Launcher (2026-07-03)

A full read-through of both repos — the **image/library repo** (OpenCode-Setup)
and the **user-facing launcher** (Opencode-Launcher) — looking for functional
improvements, feature opportunities, UX gains, and maintainability work. The
system is live and working; nothing below is an emergency, but several items
are real bugs worth verifying against the live deployment.

Legend: 🔴 fix (behavior is wrong today) · 🟡 improvement · 🔵 idea/discussion.

---

## 1. Current functionality — bugs and refactors

### 🔴 1.1 The launcher doesn't know JFrog or Confluence exist (drift)

Image **0.0.6** added the JFrog and Confluence MCP servers with an "Action
required: edit .env (new MCP credentials)" line. The launcher has **zero**
knowledge of them:

- `Opencode-Launcher/.env.example` — no `JFROG_*` / `CONFLUENCE_*` /
  `DISABLE_JFROG_MCP` / `DISABLE_CONFLUENCE_MCP` keys.
- `lib/config.sh` `config_schema()` / `wizard_keys()` / `field_help_text()` —
  absent, so `--reconfigure`, the ncurses editor and `--config` can't set or
  show them.
- `lib/doctor.sh` `doctor_check_env_keys()` optional list — absent.
- `lib/allowlist.sh` (`--show-allowlist`, boot summary line) — still says
  "LLM + Bitbucket/Jira/GitLab".
- `CHANGELOG.md` image-releases section — stops at 0.0.5; 0.0.6 is missing.

Because the drift check (`check_env_drift`) compares the user's `.env` against
the **launcher's own** `.env.example`, it can never flag this either. A
launcher user can only enable those MCPs by hand-editing `.env` with keys they
have no way to discover.

**Fix now:** add both service blocks to `.env.example`, the schema, the wizard,
doctor's optional list, the allowlist report, and add the 0.0.6 image entry to
the launcher CHANGELOG.

**Fix structurally:** see §4.1 — this class of drift will recur every time the
image grows a service.

### 🔴 1.2 `ENABLE_SESSION_LOGS=0` silently does nothing (tmpfs mount can't succeed)

`opencode/entrypoint.sh` (§5) tries `mount -t tmpfs … || log "tmpfs mount
failed (no CAP_SYS_ADMIN?); using volume anyway"`. Mounting tmpfs requires
`CAP_SYS_ADMIN`, and the compose file only grants
`CHOWN,SETUID,SETGID,DAC_OVERRIDE` — so the mount **always** fails and session
logs are **always persisted**, even when the user asked for the privacy mode.
The fallback message even guesses the cause correctly.

**Fix:** don't do this inside the container. Add a small compose overlay
(`docker-compose.session-logs-off.yml`) that replaces the `oc_state` volume
with a compose-level `tmpfs:` mount, applied by `scripts/opencode` / the
launcher when `ENABLE_SESSION_LOGS=0`. That needs no extra capability.
(Verify on the live system first: `docker exec opencode-<slug> mount | grep
tmpfs` with `ENABLE_SESSION_LOGS=0`.)

### 🔴 1.3 git-guard is bypassed by global options before the subcommand

`opencode/git-guard` dispatches on `"${1:-}"`, so it only guards when the
*first* argument is the subcommand. `git -C /workspace push`, `git -c
foo=bar push`, `git --git-dir=… fetch` all sail past the guard — and `git -C`
is something agents emit routinely, so this isn't just a determined-user
bypass (which the docs rightly disclaim); it's an *accidental* hole.

**Fix:** scan forward past known global options (`-C <path>`, `-c <kv>`,
`--git-dir=…`, `--work-tree=…`, `--namespace=…`, `-p/--paginate`, etc.) to find
the real subcommand before the `case`. Also consider adding `ls-remote` and
`submodule` to the guarded set for consistency.

### 🔴 1.4 policy.yaml env values keep their literal quotes

`entrypoint.sh` §7 parses `policy.yaml` with `IFS=: read` and never strips
quotes, so `OPENCODE_DISABLE_TELEMETRY: "1"` exports as the 3-character value
`"1"`, `DO_NOT_TRACK` likewise, and `NO_PROXY: "localhost,…"` exports with
quotes — **overwriting** the correct unquoted `NO_PROXY` that compose set. The
`BUN_CONFIG_SKIP_INSTALL_PACKAGES` comment in `policy.yaml` shows this was
already noticed once and worked around per-key instead of fixed in the parser.

Impact is mostly latent (Squid is the real telemetry backstop; undici doesn't
consult `NO_PROXY`), but any tool doing `=== "1"` on these vars sees the wrong
value. **Fix:** strip one layer of surrounding quotes in the parser (the
`trim()` helper in the same file already does exactly this for LLM vars), then
delete the per-key workaround comment.

### 🔴 1.5 Launcher management commands clobber the recorded port

`lib/project.sh` `derive_project_settings()` **recomputes** the port with
`port_in_use 4096` and **rewrites** `.envs/<slug>.env` on every call — and it's
called by `--down`, `--logs`, and `--shell`. If the project itself is running
on 4096, those commands see 4096 busy, pick 4097, and record it. After that,
`--status <repo>` (which reads the recorded file) reports the **wrong web-UI
URL**. Same root cause: re-running `./start.sh <repo>` while that repo's stack
is already up *moves* its port (4096 → 4097) instead of reusing it, so ports
aren't sticky per project.

**Fix:** make the port sticky — if `.envs/<slug>.env` records a port and that
port is either free *or* owned by this project's own `oc-publish` container,
reuse it. And make the read-only commands (`--logs`, `--shell`, `--status`)
stop regenerating the env file at all; only boot and `--down` need compose
interpolation, and `--down` should reuse the recorded values verbatim.

### 🔴 1.6 TROUBLESHOOTING tells users to grep a log Squid never writes

`squid/squid.conf` sets `access_log none` (deliberately, to avoid retaining
conversation data), but `docs/TROUBLESHOOTING.md` § "Squid is blocking
something I need" says to run `docker compose logs squid | grep TCP_DENIED` —
which can never match. Self-service allowlist debugging is currently
impossible.

**Fix:** log **denials only** — no payloads, no allowed traffic, so the privacy
stance holds:

```
acl denied_req all
access_log stdio:/dev/stdout squid !allowed_dst
```

(or an equivalent `access_log … deny`-filtered line), and keep the doc as-is.
Denied-destination hostnames are exactly what a developer needs to fix their
own allowlist.

### 🔴 1.7 TROUBLESHOOTING "I broke my user layer" names a volume that doesn't exist

The doc says `docker volume rm opencode-${PROJECT_SLUG}_oc_cfg_${PROJECT_SLUG}`;
the actual volume (compose `volumes:` block) is
`opencode-${PROJECT_SLUG}_cfg`. The command fails for anyone who follows it.
Better still: give the launcher a `--reset-config <repo>` command (see §3.6) so
nobody types volume names by hand.

### 🟡 1.8 Vestigial sudoers entry widens the in-container blast radius

`opencode/Dockerfile` grants `dev` passwordless sudo for
`usermod`, `groupmod`, and `chown` — but the UID remap runs in the entrypoint
**as root**, before dropping to `dev`. Nothing legitimate uses this sudo. The
practical risk: an agent (or a careless `--shell` session) can `sudo chown -R
0:0 /workspace` — i.e. re-own the **host** repo bind-mount to root, which is
exactly the kind of accidental host-side damage the rest of the design guards
against. **Fix:** delete `/etc/sudoers.d/dev-uid-remap` (and consider removing
`sudo` from the image entirely; `gosu` covers the entrypoint's needs).

### 🟡 1.9 Credential helper matches hosts by suffix glob

`entrypoint.sh` §6 generates case arms like `*bitbucket.internal.example)`.
The Squid allowlist bounds the real risk, but the correct match is exact-host:
`${bb_host}) … ;;` (git's `host=` line is already a bare host; the port is
stripped one line earlier). One-character-class fix, removes a
`evil-bitbucket.internal.example`-shaped edge entirely.

### 🟡 1.10 `scripts/doctor.sh` treats Bitbucket credentials as required

Its required-var loop FAILs on empty `BITBUCKET_USER`/`BITBUCKET_PAT`, but
`.env.example` (and the launcher) treat Bitbucket as optional. A
Bitbucket-less setup that works fine reports FAIL. Move those two (plus
`BITBUCKET_BASE_URL`) to a warn-if-unset optional list, mirroring the
launcher's doctor.

### 🟡 1.11 Unpinned bases and an EOL Node

- `squid/Dockerfile` builds `FROM ubuntu/squid:latest` — a moving base under a
  system whose whole philosophy is pinning (cf. the `OPENCODE_VERSION` /
  plugin-ref discipline in the opencode image). Pin a tag or digest.
- `opencode/Dockerfile` `NODE_MAJOR=20`: Node 20 reached end-of-life April
  2026. Bump to 22 LTS on the next image release and re-test the MCP servers
  (pure undici/zod — low risk).

### 🟡 1.12 Entrypoint/doctor MCP blocks: five copies of the same gate

`entrypoint.sh` §4b has five nearly identical credential-gate blocks, and
`scripts/doctor.sh` mirrors them again in the `*_want` computations. Adding
service #6 means editing four places (plus the launcher — see §4.1). Replace
with a table walked in a loop:

```
# service|needs_user|extra
for svc in "bitbucket|1" "gitlab|1" "jira|0" "jfrog|0" "confluence|0"; do … done
```

deriving `<SVC>_BASE_URL` / `<SVC>_USER` / `<SVC>_PAT` / `DISABLE_<SVC>_MCP`
via `${!var}` indirection. The doctor can walk the same table. This turns
"add a service" into: drop the server dir, add the allowlist conf, add one
table row, add `.env.example` keys.

### 🟡 1.13 MCP servers: ~2,600 lines with 5× duplicated plumbing

Each `opencode/mcp-servers/*/index.js` re-implements: env validation, the
undici `ProxyAgent` dispatcher, auth-header construction, the
status-code→message ladder, and truncation helpers. Bitbucket also uses the
older low-level `Server` API while the other four use `McpServer`.
Extract a shared `mcp-servers/_lib/common.js` (created once in the image; the
`mcp-build` glob loop needs a one-line tweak to skip `_lib` or vendor it) with
`makeDispatcher()`, `bearerClient(base, pat)` / `basicClient(base, user, pat)`,
and a `toolError(err)` that **doesn't dump `err.stack`** into model context
(today's error text includes the full stack — pure token noise for the agent).
Normalize Bitbucket onto `McpServer` while you're there.

### 🟡 1.14 Entrypoint remap `chown -R` cost

When `HOST_UID` ≠ 1000, every boot runs `chown -R … /home/dev /workspace` —
on a large repo that's a slow boot every time (and it re-owns files the host
user already owns correctly in the common same-UID case, where it's skipped —
the cost hits exactly the non-1000 users). Consider `chown` only when a probe
file's owner mismatches, or restrict the recursive pass to `/home/dev` and fix
`/workspace` ownership only when a write-probe fails.

### 🔵 1.15 Removals / simplifications worth considering

- **`scripts/new-project.sh`** predates the launcher's "one clone, many repos"
  model and does a full `cp -a` of the scaffold (including `ca/` certs and any
  `extra-allowlist.d/` contents) per repo. If your colleagues are all on the
  launcher now, demote this to a maintainer-only note or delete it.
- **`OPENCODE_SERVER_PASSWORD`** exists only in the setup repo's
  `.env.example`; nothing in compose or the entrypoint wires it, and the
  launcher doesn't carry it. If upstream opencode doesn't read that exact env
  var, the knob is dead — verify and either wire it or drop it.
- **`docker-compose.user-layer.yml` duplication** — both repos carry one;
  that's covered by SYNC.md, fine, but it's another reason for §4.1.

---

## 2. New features — prioritized brainstorm

Ordered by (value to your colleagues ÷ effort), with reasoning.

1. **Launcher awareness of image releases** (high value, low effort).
   Bake the image version + CHANGELOG into the image
   (`LABEL org.opencontainers.image.version=$VERSION`, copy `CHANGELOG.md` to
   `/etc/opencode/CHANGELOG.md`). On boot, when the digest-change nudge fires
   (`report_digest_update`), the launcher can `docker inspect` the label and
   print "image 0.0.6 — changelog: …" or even
   `docker run --rm <img> sed -n '/^## \[0.0.6\]/,/^## /p' /etc/opencode/CHANGELOG.md`.
   Today the digest nudge says *something* changed but not *what* — closing
   that loop is the single best "keep users informed" win, and it's the
   delivery vehicle for "Action required" lines.

2. **`/report-bug` command** (already sketched in MAINTAINERS.md future work —
   promote it). In a closed environment, "paste your doctor output into a
   ticket" is friction that means bugs go unreported. Bundle: launcher/image
   versions, digest, doctor output, last N session messages (with an explicit
   consent prompt), POST to the already-allowlisted Jira API. Everything it
   needs (Jira MCP creds, allowlist) already exists.

3. **`--update` / launcher self-update check** (medium value, low effort).
   Users must remember to `git pull` the launcher. A best-effort
   `git fetch && git log HEAD..origin/main --oneline` on boot (or under
   `--doctor`), printing "launcher update available (0.6.0 → 0.7.0)", closes
   the second half of the update story. Needs only the internal git host,
   which users already cloned from; degrade silently offline.

4. **Multi-repo mounts** (`--also <path>[:ro]`) (high value for developers,
   medium effort). Colleagues working on service A routinely need library B
   read-only for reference. Generate a tiny overlay per extra mount
   (`/workspace-extra/<slug>`) the way the user-layer overlay works. The slug
   derivation and env-file generation machinery is already there.

5. **MCP status in `--status`** (medium value, low effort). The image's doctor
   already knows how to check which MCPs are wired
   (`jq .mcp.<svc> ~/.config/opencode/opencode.json` in-container). Surface
   "MCPs: bitbucket ✓ jira ✓ gitlab – jfrog – confluence –" in
   `--status <repo>` so "why doesn't the agent see Jira?" is answerable
   without `--shell`.

6. **Non-interactive run mode** (`./start.sh --exec "<prompt>" <repo>`)
   (medium value, medium effort). Boots detached, runs `opencode run
   "<prompt>"` in the container, prints the result, tears down. Enables
   scripting/CI use (nightly "summarize new TODOs", batch refactors) and makes
   the stack useful beyond interactive sessions.

7. **RAG MCP sidecar** (planned in ARCHITECTURE.md). The `oc_internal`
   network is already reserved for it. Highest ceiling of anything here
   (internal-docs + cross-repo code search grounded answers) but also the
   biggest lift; keep it behind the smaller wins above.

8. **Team config layer** (lower priority). Like `USER_LAYER_PATH` but a
   team-shared, git-versioned layer (e.g. a repo of team skills mounted
   read-only). Today team-wide content must ride the image (maintainer
   bottleneck); a team layer would let leads ship skills without cutting an
   image. Do it only if colleagues actually start writing skills.

---

## 3. UX improvements (mostly launcher)

1. **Pull policy** — every `./start.sh` runs `docker manifest inspect` + a
   full `compose pull` before boot. On a slow/unavailable registry, that's the
   difference between "instant TUI" and a blocked boot. Add
   `PULL_POLICY=always|daily|never` (or `--no-pull`): on `daily`, skip the
   pull when the last successful pull for this tag is <24h old (timestamp file
   next to the digest state); on registry error with a local image present,
   warn and boot anyway instead of failing.

2. **Sticky ports** (the fix for §1.5, but it's UX too): the printed web-UI
   URL for a given repo shouldn't change between runs — colleagues bookmark
   it, and the desktop app pins `localhost:4096` by default.

3. **First-run wizard grouping** — 14 sequential prompts is a wall. Group the
   linear wizard by service with a gate question ("Configure Bitbucket?
   [y/N]" → skip 3 keys). The ncurses path already solves this with its menu;
   the plain path (CI, no whiptail) is where the wall stands. Also: once
   JFrog/Confluence land (§1.1), that's 18 prompts — grouping stops the wizard
   scaling linearly with services.

4. **`--doctor` runtime checks** — the launcher doctor validates host-side
   preconditions but nothing live. When a stack is running, add the image
   doctor's two best checks: LLM reachable through Squid from inside the
   container, and MCP wiring vs. credential expectations. Those two are where
   the real support pain lives ("agent says Unauthorized", "agent can't see
   Jira").

5. **Persist should be more discoverable at exit** — the "pass --persist next
   time" hint prints *after* teardown already happened. Consider an exit-time
   prompt when at a tty ("Keep stack running? [y/N] (5s timeout → No)") or at
   least print the hint *before* attaching, both places.

6. **`--reset-config <repo>` / `--reset-state <repo>`** — wraps `docker volume
   rm` of the right per-project volume (fixes the broken doc recipe from §1.7,
   and gives "my user layer is broken / start fresh" a supported one-liner).

7. **Web-UI `/workspace` wart — consider an interim fix in the image.** The
   stack owns `oc-publish`; replacing raw socat with a ~40-line reverse proxy
   that rewrites the `x-opencode-directory` header to `/workspace` **only when
   the client sends exactly `/`** would erase the #1 documented limitation for
   web/desktop users without waiting for upstream #14445. It's a hack with a
   clear removal marker (same pattern as the SYNC.md reversibility marker),
   and it would delete the warn-block every boot prints. Worth a spike; the
   risk is coupling to an undocumented client header, which you already depend
   on for the documented workaround.

8. **Wizard should offer plugin choices as a menu** — `ENABLED_PLUGINS` is a
   free-text field with a hint; the ncurses path could present a checklist
   (whiptail `--checklist`) of `KNOWN_PLUGINS` instead. Small, nice.

---

## 4. Maintainability

1. **One source of truth for the env schema (kills the §1.1 drift class).**
   Today the ".env schema" lives in ~6 places across two repos: image
   `.env.example`, entrypoint gates, image doctor, launcher `.env.example`,
   launcher `config_schema()`, launcher doctor. Proposal: the **image ships a
   machine-readable manifest** — e.g. `/etc/opencode/manifest.json`:

   ```json
   { "image_version": "0.0.6",
     "env_keys": [ {"key":"JFROG_BASE_URL","group":"JFrog","type":"url","required":false,…} ],
     "mcps": ["bitbucket","gitlab","jira","jfrog","confluence"],
     "plugins": ["superpowers","dcp","opencode-workspace"] }
   ```

   The launcher then gets a doctor check (and boot-time warn) that diffs the
   pulled image's manifest keys against its own schema: *"image 0.0.6 declares
   keys your launcher doesn't know: JFROG_BASE_URL … — update the launcher"*.
   Even if the launcher schema stays hand-written for prompts/help-text, drift
   becomes **loud** instead of silent. (`KNOWN_PLUGINS` and the allowlist
   summary line can read the same manifest and stop being hand-maintained
   copies.)

2. **Make SYNC.md executable.** The compose-sync contract is a prose checklist
   humans must remember. Vendor a reference copy of the maintainer compose
   blocks into the launcher's `tests/` and add a bats test asserting the
   synced blocks (`:z` mounts, `${IMAGE_TAG}` on all three services, network
   topology) still match `docker/docker-compose.yml`. Updating the reference
   file becomes the deliberate act SYNC.md asks for; forgetting becomes a red
   test instead of a silent drift.

3. **CI for both repos.** The launcher has a genuinely good bats suite (260
   tests) but nothing runs it automatically; the setup repo has **no tests at
   all**. Minimum pipeline (TeamCity, per your plan, or the public GitHub
   mirrors):
   - both: `shellcheck` on all shell (the launcher is already
     shellcheck-annotated; the entrypoint/doctor/git-guard are not).
   - launcher: `tests/run.sh`.
   - setup: `docker build` both images; `squid -k parse` against the built
     squid config; `node --check` each MCP `index.js`; then the
     `MAINTAINERS.md` smoke test scripted.
   - setup: a small bats suite for the pure-bash entrypoint helpers
     (`disabled_for`, `trim`, the policy parser, cred-helper generation) —
     they're exactly the kind of quoting-sensitive code that regresses.

4. **Script the release.** `MAINTAINERS.md` is 5 manual steps; make it
   `scripts/release.sh <version>` that: asserts CHANGELOG has a `[$version]`
   section with an Action-required line, asserts `ca/` is non-empty, builds
   both images, runs the smoke test, pushes on `--push`. Cheap insurance
   against "pushed image, forgot changelog" — which already half-happened
   (§1.1: launcher changelog missing 0.0.6).

5. **Loop-ify the per-service shell blocks** (§1.12) so service #6's diff is
   small and mechanical, matching the "worked example" story MCP_SERVERS.md
   already tells.

6. **Shared MCP helper lib** (§1.13) — one place for proxy/auth/error
   conventions instead of five.

7. **Docs are a genuine strength** — ARCHITECTURE/MCP_SERVERS/TROUBLESHOOTING
   with verified-fact sections and reversibility markers is better than most
   professional repos. The two doc bugs found (§1.6, §1.7) are the only rot;
   both are one-line fixes. Keep the "canonical reference; if code disagrees,
   fix one of them" discipline.

---

## 5. Overall product polish

- **Fix the four "trust the safety story" gaps first**: git-guard `-C` bypass
  (§1.3), tmpfs no-op (§1.2), sudoers chown (§1.8), quoted policy env (§1.4).
  Each is small; together they make the documented security/privacy posture
  actually match the implementation. The design itself — three networks,
  publisher sidecar, deny-by-default Squid, vendored offline plugins/MCPs —
  is sound and clearly explained.
- **Then close the launcher↔image loop** (§1.1 parity now, §4.1 manifest so it
  can't recur, §2.1 changelog surfacing so users see what changed).
- **Then the two biggest daily-driver UX wins**: pull policy (§3.1) and sticky
  ports (§3.2/§1.5).
- The web-UI `/workspace` interim fix (§3.7) is the highest-leverage *end-user*
  item if colleagues prefer the web/desktop UI; skip it if everyone lives in
  the TUI.

## Suggested order of work

| # | Item | Repo | Size |
|---|------|------|------|
| 1 | Launcher JFrog/Confluence parity + 0.0.6 changelog entry (§1.1) | launcher | S |
| 2 | git-guard option-scan (§1.3), sudoers removal (§1.8), policy quote-strip (§1.4), cred-helper exact match (§1.9) | setup | S |
| 3 | Session-logs-off overlay (§1.2) + doc fixes (§1.6, §1.7) | both | S |
| 4 | Sticky ports / stop regenerating env in read-only commands (§1.5) | launcher | M |
| 5 | Pull policy (§3.1) | launcher | S |
| 6 | Image manifest + launcher drift check (§4.1) | both | M |
| 7 | CI: shellcheck + bats + build/parse checks (§4.3) | both | M |
| 8 | Image-changelog surfacing on digest change (§2.1) | both | S |
| 9 | Entrypoint/doctor service-table refactor (§1.12) + MCP shared lib (§1.13) | setup | M |
| 10 | `/report-bug` (§2.2), `--exec` (§2.6), multi-repo mounts (§2.4), RAG (§2.7) | both | L |

## Open questions for the maintainer

1. **Scope of implementation:** which of the table above do you want done now
   (and in which repo/branch)? Items 1–5 are safe, small, and I can implement
   and test them immediately.
2. **`ENABLE_SESSION_LOGS=0`:** does anyone actually rely on it today? If yes,
   the tmpfs fix (§1.2) should jump the queue; if no one uses it, consider
   dropping the knob instead of fixing it.
3. **Web vs TUI usage split among colleagues:** is the web/desktop UI popular
   enough to justify the header-rewriting `oc-publish` spike (§3.7), or does
   everyone live in the TUI?
4. **Registry latency:** how slow is an Artifactory pull round-trip in
   practice? That decides whether pull-policy (§3.1) defaults to `daily` or
   stays `always`.
5. **CI reality:** is TeamCity actually available/approved for these repos, or
   should CI target the public GitHub mirrors (which lack the corp CA — build
   checks would run with an empty `ca/`, which the Dockerfile already
   tolerates)?
6. **Launcher users and JFrog/Confluence:** did anyone hand-add those keys to
   their `.env` already? If yes, the parity change must not fight their
   existing lines (it won't — drift check keys off `.env.example` — but worth
   knowing for the changelog wording).
