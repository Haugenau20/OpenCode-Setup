---
description: Self-paced, hands-on walkthrough of the OpenCode workplace — guides one developer through the launcher commands (on their host) and the in-container skills, safety gates, and edit→commit loop, at their own speed.
---

You are guiding **one developer** through a hands-on, self-paced first session
with this OpenCode workplace. Unlike `/tour` (which you drive for an audience),
here the *developer* does the doing — you set up each step, invite them to act,
wait, then react to what actually happened.

Two kinds of step, and you must be clear which is which each time:

- **In here (this TUI):** ask them to type something to you, or run a shell
  command inside the container. You can see and react to the result directly.
- **On their host (a separate terminal, outside this container):** the launcher
  (`./start.sh …`) lives on their machine, not in this box — you cannot run it.
  For those steps, tell them to open a terminal in their launcher checkout and
  run the command there, then paste the output back to you so you can talk
  through it.

Work through the checkpoints **one at a time**: explain the step in a sentence or
two, tell them exactly what to type/run and *where*, then STOP and wait for their
result before moving on. Keep a short checklist and tick items off. If a step is
blocked in their environment (no credentials, host refused, git read-only), treat
that as a real, useful outcome — explain it, then continue.

### Checkpoint 1 — Get your bearings (host)
Have them run, in their launcher checkout on the host:
`./start.sh --doctor` and `./start.sh --status`. Walk through the PASS/WARN/FAIL
report and what's running. This is the read-only health check they'll reach for
whenever something's off.

### Checkpoint 2 — Look inside the box (in here)
Ask them to run `/plugins`, and to ask you to list the skills, agents, and
commands in `~/.config/opencode/`. Confirm they can see the bundle that shipped
in the image. Connect it back: this is what the backbone repo baked in.

### Checkpoint 3 — Use a skill the house way (in here)
Have them ask for something a `*-fetch` skill covers (e.g. "fetch Jira issue
ABC-123" or "find a Confluence page about onboarding"). Point out the house rule
routing it through the skill rather than raw MCP tools. If no service is
configured for them, show what the request looks like and explain it auto-enables
once they add credentials via `./start.sh --reconfigure` on the host.

### Checkpoint 4 — Hit the safety gates on purpose
In here: have them try `git push` and watch the workplace policy block it (unless
they set `ALLOW_REMOTE_GIT=1`), then try a host off the allowlist
(`curl -sS --max-time 5 https://example.com`) and see the egress wall refuse it.
On the host: have them run `./start.sh --show-allowlist` to see, honestly, what
egress is permitted. Make sure they understand *why* each was blocked.

### Checkpoint 5 — Do a real loop (in here)
Walk them through a tiny change in `/workspace`, then ask you (or the `sidekick`
agent) to name a branch and write a commit message. Confirm the branch follows
`branch-naming` and the message follows `commit-conventions`. Do not push.

### Checkpoint 6 — Make it yours (host)
Show them the self-service edges, all on the host, no rebuild:
- `USER_LAYER_PATH` in `.env` → host-editable personal agents/skills/commands.
- `extra-packages.txt` → bake in an apt/pip tool (built on the host, runtime
  stays locked).
- `extra-allowlist.d/*.conf` → allow an extra egress host.
- `ENABLED_PLUGINS` → opt into a baked-in plugin.
Invite them to add one trivial thing (e.g. a personal command under the user
layer, or one package), re-run `./start.sh <repo>`, and see it take effect. Point
them at the launcher's `docs/CUSTOMIZING.md`.

### Close
Recap what they tried across both repos — the launcher commands on the host and
the live machinery in here — and remind them the `guide` agent (Tab) is always
there. Encourage them to bring a real task next time.
