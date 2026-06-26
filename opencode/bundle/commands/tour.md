---
description: Run an interactive, projector-friendly tour of the OpenCode workplace — the launcher that got you here, the locked-down image you landed in, the bundled skills and house rules, the safety gates, a live MCP fetch, and a real edit→commit loop.
---

You are now hosting a **live, interactive tour** of this OpenCode workplace for
an audience of software developers. Demonstrate the workplace by *exercising* the
parts that live in this container, and *explaining* the parts that live on the
host. This is meant to be driven from the front of a room, so keep each section
short and pause for interaction between them.

Run the sections **in order**, but do **one section at a time**: perform or
explain it, show the real output where you can, give a one- or two-sentence
takeaway, then STOP and ask whether to continue, dig deeper, or skip ahead. Do
not dump all sections at once.

**Live vs. narrated — read this first.** You are running *inside* the locked-down
container. Sections that touch the bundle, the gates, or MCP you can run for
real. Sections about the **launcher** (`./start.sh …`) run on the developer's
**host**, outside this container — you CANNOT execute those; explain them, and
let the presenter flip to a host terminal if they want to show them. For any live
move that can't run here (no credentials, host refused, git read-only), that
refusal **is the point** — explain what was blocked and why. Never invent output.

### 0. The two-repo picture (narrated)
Explain, in a few sentences, what the audience is looking at:
- **The launcher** (`Opencode-Launcher`) is the thin glue a developer runs on
  their host: `./start.sh <repo>` pulls pre-built images from Artifactory, wires
  them with docker compose, mounts their repo at `/workspace`, and drops them
  into this TUI. On first run it walks a secrets wizard (required: LLM endpoint +
  key + Artifactory path; Bitbucket/Jira/GitLab optional), then prints the image
  **sha256 digest** for reproducibility.
- **This backbone** (`OpenCode-Setup`) is where the trust lives: it builds the
  images — the agent bundle, the Squid allowlist, the git guard, the MCP servers,
  the CA. The maintainer cuts image tags here; the launcher consumes them.
- Takeaway: *the launcher is the front door; this backbone is the sealed box
  you're now inside.* Then present the menu (sections 1–6) and start with 1.

### 1. "What am I?" — the bundle, live
- List the real contents of `~/.config/opencode/skills/`, `/agents/`, and
  `/commands/` (they're symlinks into the shipped image bundle).
- Run `/plugins` (or read `~/.config/opencode/plugin/`) to show the plugin
  catalog and which are ON.
- Takeaway: every image built from the backbone carries the same batteries.

### 2. House rules — skills over raw tools
- Show `~/.config/opencode/AGENTS.md` (or its headline rule): service access goes
  through the `*-fetch` skills, not the raw `jira_*` / `bitbucket_*` MCP tools.
- Takeaway: conventions ship *with* the image, so the agent follows house style
  by default.

### 3. The safety gates — watch them trip
- **Git guard:** run `git push` (expected to be blocked unless
  `ALLOW_REMOTE_GIT=1`). Show the "blocked by workplace policy" message, and
  point out the shell prompt tag `git:ro` vs `git:rw`.
- **Egress wall:** attempt a host NOT on the allowlist, e.g.
  `curl -sS --max-time 5 https://example.com` — expect Squid to refuse it.
  Contrast with the LLM endpoint and configured services, which *are* reachable.
- Takeaway: the container can't exfiltrate or push by accident — egress is an
  allowlist, remote git is opt-in.

### 4. A live service fetch (only if configured)
- Inspect which MCP services are actually wired up (`~/.config/opencode/opencode.json`
  → `.mcp`, or just attempt the skill). The launcher surfaces Bitbucket/Jira/
  GitLab today; newer images also ship JFrog and Confluence — so check, don't
  assume.
- If Jira is available, use the `jira-fetch` skill to fetch one issue or run a
  small JQL search; use `confluence-fetch` if that's what's live.
- If nothing is configured here, say so plainly — "no service credentials in this
  container, so those MCP tools aren't loaded" — and explain they auto-enable
  when their `.env` credentials are set (via the launcher's wizard).
- Takeaway: through guarded, read-only skills the agent can see the company's
  real Jira/Confluence/Bitbucket.

### 5. The real loop — edit → commit, by the house rules
- Make a tiny demo change in `/workspace` (e.g. a one-line note in a scratch
  file). Name any branch per `branch-naming` and write the commit message per
  `commit-conventions`. Do NOT push.
- Takeaway: the everyday loop already follows house conventions because the
  skills enforce them.

### 6. Customizing it — the launcher's host-side powers (narrated)
You can't run these from in here, but they're the punchline for *why the split
exists* — all self-service, no rebuild of the shared base, all on the host:
- `extra-packages.txt` — bake extra apt/pip tools into a thin local image layer
  (built on the host's real internet, not through Squid; runtime stays locked).
- `extra-allowlist.d/*.conf` — extend the egress allowlist locally.
- `USER_LAYER_PATH` — host-editable personal agents/skills/commands.
- `ENABLED_PLUGINS` — opt into the baked-in plugins (offline, no network).
- `IMAGE_TAG` pinned to a version or `@sha256` digest — reproducible images.
- Host management commands: `--doctor`, `--status`, `--show-allowlist`,
  `--shell`, `--logs`, `--persist`, `--detach`, `--reconfigure`.
- Takeaway: the backbone stays sealed and shared; each developer customizes at
  the edges through the launcher.

### Close
Recap in two lines: the launcher got them in, the backbone is what they're inside,
and everything they saw (bundle, rules, gates, MCP) ships in the image. Then hand
off: "summon the `guide` agent (Tab) any time, and run `/try-it` for a hands-on,
self-paced version — including the host-side launcher commands."
