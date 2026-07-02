# OpenCode Workplace — Presenter Run-Sheet

A back-and-forth demo: you boot the launcher, then hand the room over to the
agent via `/tour`. Two repos on stage — the **launcher** (the front door your
colleagues run on their host) and the **backbone** (the repo that builds the
locked-down image they land in). The demo agent/commands ship as a **user layer**
on top of the stock image, so there's **no custom image to build**.

> One sentence to open with: *"You run one command on your machine; it drops you
> into a sealed box that already knows your tools, your conventions, and what
> it's allowed to touch. Let me show you."*

---

## 0. The story (your through-line)

1. **First-time setup is one command** → `./start.sh <repo>`.
2. **You land in a sealed box** → bundle, house rules, MCP — all baked in.
3. **The box can't misbehave** → git guard + egress wall, watch them trip.
4. **You customize at the edges, not the core** → launcher self-service
   (this very demo is a user-layer add-on — proof of the point).
5. **They can do this themselves** → hand off `/try-it`.

Keep returning to: *launcher = front door, backbone = the box.*

---

## 1. Before the room (pre-flight checklist)

Do this the day before **and** 10 minutes before:

- [ ] **Rehearse the whole thing once, end to end.** Non-negotiable — the live
      MCP fetch and the image pull are the two things most likely to surprise you.
- [ ] **`docker login <registry-host>`** so the image pull doesn't stall on auth.
- [ ] **Launcher main is pushed** (your JFrog/Confluence addition) and your
      launcher checkout is on it: `git -C <launcher> pull`.
- [ ] **Drop in the user layer.** Copy this `user-layer/` folder into the
      launcher (a tracked dir, e.g. `<launcher>/demo/user-layer/`) and set
      `USER_LAYER_PATH=./demo/user-layer` in the launcher `.env`. That's what
      makes `guide` / `/tour` / `/try-it` appear — **no image build needed**.
- [ ] **Use a normal released `IMAGE_TAG`** (e.g. `latest` or a pinned version).
      The demo content rides on top via the user layer, not in the image.
- [ ] **Pick a demo repo** with a git remote and something to look at — small,
      uncontroversial. It mounts at `/workspace`.
- [ ] **Services for the live fetch:** put real **Jira** (and/or **Confluence**)
      creds in `.env` so Section 4 actually returns a ticket. This is the
      "whoa" moment — make sure it works in rehearsal.
- [ ] **Leave `ALLOW_REMOTE_GIT=0`** (default) so the git guard trips on cue.
- [ ] **Enable a couple of plugins** so `/plugins` shows ON rows, not all OFF.
- [ ] **Terminal: big font, dark theme, wide window.** Have a second host
      terminal tab open for the optional host-side commands.
- [ ] **Know your egress test host.** `https://example.com` is off-allowlist;
      confirm in rehearsal that Squid refuses it (not a silent hang).

---

## 2. The demo `.env` (launcher checkout)

Pre-stage this as `<launcher>/.env` (fill the real values). Secrets never appear
on screen if you instead enter them via the wizard — but pre-staging is the
low-risk default for a live room.

```dotenv
# --- required ---
LLM_API_BASE=https://llm.internal.example/v1
LLM_API_KEY=<your bearer token>
IMAGE_REGISTRY=<your.artifactory.example>/opencode-workplace
IMAGE_TAG=latest

# --- the demo content (user layer, no image rebuild) ---
USER_LAYER_PATH=./demo/user-layer

# --- make Section 4 (live fetch) light up ---
JIRA_BASE_URL=https://jira.internal.example
JIRA_PAT=<jira pat>
# CONFLUENCE_BASE_URL=https://confluence.internal.example:8090
# CONFLUENCE_PAT=<confluence pat>

# --- gates stay at defaults so they trip on cue ---
ALLOW_REMOTE_GIT=0
ENABLE_SESSION_LOGS=1

# --- show some plugins ON in /plugins ---
ENABLED_PLUGINS=superpowers dcp
```

> If you'd rather show the wizard live: delete `.env` first, run `./start.sh
> <repo>`, and let the ncurses editor walk you through it — secrets are entered
> in a hidden passwordbox, so the key never shows on the projector. Required
> fields are marked `(REQUIRED)` and it won't let you finish until they're set.
> (Re-add the `USER_LAYER_PATH` line afterward — the wizard doesn't prompt for
> it.)

---

## 3. Run of show

### Act 1 — First-time setup (host terminal) · ~3 min

| You do | You say | They see |
|---|---|---|
| `cd <launcher>` then `./start.sh ~/code/demo-repo` | "One command. It copies `.env.example` to `.env`, pulls the images from Artifactory, and wires them together." | boot logs, image pull |
| *(if showing the wizard)* walk the ncurses fields | "Three things are required — LLM endpoint, key, registry. Bitbucket/Jira/GitLab are optional. Secrets are hidden." | the whiptail editor |
| let it finish | "Notice the **sha256 digest** it printed — that's a reproducibility/tamper anchor; a tag can move, a digest can't." | `image: …@sha256:…`, then the TUI |
| TUI attaches at `/workspace` | "And we're inside the box, rooted at my repo. Exiting here tears the whole stack down — one command in, one command out." | the OpenCode TUI |

> Prompt tag check: point at the shell/TUI showing `git:ro` — "remote git is
> off by default; you'll see why in a moment."

### Act 2 — Meet the agent (`/tour`) · ~8–10 min

Type **`/tour`** and let the agent host. It does **one section at a time and
pauses** — you advance by talking to it. Suggested drives:

| Section | What you type / say | The moment |
|---|---|---|
| 0. Architecture | *(it opens with this)* — "So: launcher = front door, this = the box." | sets the frame |
| 1. "What am I?" | "show me what you're made of" | it lists real skills/agents/commands + runs `/plugins` |
| 2. House rules | "what are the rules here?" | it shows `AGENTS.md` — skills over raw tools |
| 3. Safety gates | **"try to push, and try to reach the open internet"** | `git push` → *blocked by workplace policy*; `curl example.com` → Squid refuses. **This is the trust beat — let it land.** |
| 4. Live fetch | "pull me a real Jira issue" | a real ticket comes back through the guarded skill — the "whoa" |
| 5. Real loop | "make a tiny change and commit it the house way" | branch per `branch-naming`, message per `commit-conventions`, no push |
| 6. Customizing | "how would I add my own tools?" | it explains the host-side launcher powers — and you can note *this demo itself* is a user-layer add-on |

> If a section misbehaves, that's *content*: "See — it refused, and it told us
> exactly why. That's the point." Never paper over it.

### Act 3 — Customizing at the edges (host terminal, optional) · ~3 min

Flip to your second host terminal to make the self-service story concrete:

```bash
./start.sh --doctor          # PASS/WARN/FAIL health report (paste-safe)
./start.sh --show-allowlist  # the honest egress picture
./start.sh --status          # what's running, the resume command, the digest
```

Then *talk through* (no need to run): `extra-packages.txt` (bake in apt/pip
tools, built on the host's real internet, runtime stays locked),
`extra-allowlist.d/*.conf` (extend egress), `USER_LAYER_PATH` (host-editable
personal skills — *"exactly how this demo got in"*), `ENABLED_PLUGINS`, and
pinning `IMAGE_TAG` to a digest.

> The punchline: *"The shared box stays sealed and identical for everyone; you
> customize at the edges, on your own machine, without a rebuild."*

### Act 4 — Handoff · ~1 min

"Everything you saw, you can redo at your own pace. Inside the TUI, run
**`/try-it`** — it walks you through the launcher commands on your host and the
live moves in here, one checkpoint at a time. And the **`guide`** agent (Tab) is
always there to answer questions."

---

## 4. If it breaks (fast recovery)

| Symptom | Likely cause | Say / do |
|---|---|---|
| Pull stalls on `unauthorized`/`denied` | not logged into Artifactory | `docker login <registry-host>`; `--doctor` prints the exact command |
| `permission denied` from Docker | not in `docker` group | `sudo usermod -aG docker $USER && newgrp docker` |
| `/tour` / `guide` not found | user layer not mounted | check `USER_LAYER_PATH` is set in `.env` and the files are under it; re-run `./start.sh` |
| Live Jira fetch returns nothing | creds unset / wrong base URL | pivot: "no creds here, so the tools aren't even loaded — they auto-enable when you add them" (that's the security model, not a failure) |
| `git push` *succeeds* | `ALLOW_REMOTE_GIT=1` leaked in | set it to `0`, re-run; the prompt should read `git:ro` |
| `curl example.com` hangs | no timeout | always use `--max-time 5`; the refusal is the point |
| Web UI session opens at `/` | known upstream default | TUI is unaffected; in the web UI click New session → type `/workspace` |

---

## 5. One-screen cheat-sheet

```
# host
cd <launcher>
./start.sh ~/code/demo-repo        # boot + attach TUI (tears down on exit)
./start.sh --persist <repo>        # keep web UI up after you exit
./start.sh --doctor                # health report
./start.sh --show-allowlist        # egress picture
./start.sh --status                # what's running + digest
./start.sh --reconfigure           # edit secrets (wizard)
./start.sh --shell <repo>          # shell into the running container

# inside the TUI
/tour            # the guided, projector walkthrough (you drive)
/try-it          # self-paced take-home (they drive)
/plugins         # plugin catalog + ON/OFF
Tab → guide      # the onboarding host agent, any time

# the trust beats to trigger live, in /tour section 3
git push                                   # → blocked by workplace policy
curl -sS --max-time 5 https://example.com  # → refused by Squid
```

---

*Timing: ~15–18 min for the full arc; drop Act 3 to land in ~12.*
