---
description: Run an interactive, projector-friendly tour of the OpenCode workplace — demonstrates the bundled skills, house rules, safety gates, MCP fetch, and a real edit→commit loop, live.
---

You are now hosting a **live, interactive tour** of this OpenCode workplace for
an audience of software developers. Demonstrate the workplace by *exercising*
it, narrating as you go. This is meant to be driven from the front of a room, so
keep each section short and pause for interaction between them.

Run the sections **in order**, but do **one section at a time**: perform it,
show the real output, give a one- or two-sentence takeaway, then STOP and ask
whether to continue, dig deeper, or skip ahead. Do not dump all sections at
once.

For every "live move" below: actually run the command and show the real result.
If a move can't run here (no credentials, host refused, git read-only), that
refusal **is the point** — explain what was blocked and why, then continue.
Never invent output.

### 0. Open
One paragraph: this is a locked-down OpenCode container wired to the company's
internal LLM, with workplace skills/agents/commands baked in and hard safety
gates around git and network egress. Then present the menu of sections (1–5
below) and start with section 1 unless asked otherwise.

### 1. "What am I?" — the bundle, live
- List the real contents of `~/.config/opencode/skills/`,
  `~/.config/opencode/agents/`, and `~/.config/opencode/commands/`. These are
  symlinks into the shipped image bundle.
- Run the `/plugins` view (or read `~/.config/opencode/plugin/`) to show the
  plugin catalog and which are ON.
- Takeaway: every developer who builds this image gets the same batteries.

### 2. House rules — skills over raw tools
- Show `~/.config/opencode/AGENTS.md` (or the headline rule from it): service
  access must go through the `*-fetch` skills, not the raw `jira_*` /
  `bitbucket_*` MCP tools.
- Takeaway: conventions ship *with* the tooling, so the agent follows house
  style by default.

### 3. The safety gates — watch them trip
- **Git guard:** run `git push` (it is expected to be blocked unless
  `ALLOW_REMOTE_GIT=1`). Show the "blocked by workplace policy" message.
  Point out the shell prompt tag `git:ro` vs `git:rw`.
- **Egress wall:** attempt to reach a host that is NOT on the allowlist, e.g.
  `curl -sS --max-time 5 https://example.com` — expect it to be refused by the
  Squid proxy. Contrast with the fact that the internal LLM endpoint and the
  configured services *are* reachable.
- Takeaway: the container can't exfiltrate or push by accident — egress is an
  allowlist and remote git is opt-in.

### 4. A live service fetch (only if configured)
- Check which MCP services are wired up (inspect `~/.config/opencode/opencode.json`
  for `.mcp` keys, or just attempt the skill).
- If Jira is available, use the `jira-fetch` skill to fetch one issue or run a
  small JQL search and show the real result. Use `confluence-fetch` instead if
  that's what's configured.
- If nothing is configured here, say so plainly: "no service credentials in
  this container, so these tools aren't loaded" — and explain that they
  auto-enable when their `.env` credentials are set.
- Takeaway: the agent can see the company's real Jira/Confluence/Bitbucket,
  through guarded read-only skills.

### 5. The real loop — edit → commit, by the house rules
- Create a tiny demo change in `/workspace` (e.g. a one-line note in a scratch
  file). Name any branch per the `branch-naming` skill and write the commit
  message per the `commit-conventions` skill. Do NOT push.
- Takeaway: the everyday loop — branch, edit, commit — already follows house
  conventions because the skills enforce them.

### Close
Recap the five things they saw in one or two lines, then hand off: "summon the
`guide` agent (Tab) any time, and run `/try-it` on your own machine for a
hands-on, self-paced version of this."
