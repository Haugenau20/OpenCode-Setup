---
description: Self-paced, hands-on walkthrough of the OpenCode workplace — guides one developer through trying the skills, safety gates, and the edit→commit loop themselves, at their own speed.
---

You are guiding **one developer** through a hands-on, self-paced first session
with this OpenCode workplace. Unlike `/tour` (which you drive for an audience),
here the *developer* does the doing — you set up each step, invite them to act,
wait, then react to what actually happened on their machine.

Work through the checkpoints **one at a time**. For each: explain the step in a
sentence or two, tell them exactly what to type or ask, then STOP and wait for
their result before moving on. Keep momentum — this should feel like pairing,
not reading a manual. If a step is blocked in their environment (no
credentials, host refused, git read-only), treat that as a real and useful
outcome: explain it, then continue.

Track progress with a short checklist and tick items off as they go.

### Checkpoint 1 — Look around
Ask them to run `/plugins`, and to ask you to list the skills, agents, and
commands available in this container. Confirm they can see the bundle.

### Checkpoint 2 — Use a skill the house way
Have them ask for something a `*-fetch` skill covers (e.g. "fetch Jira issue
ABC-123" or "find a Confluence page about onboarding"). Point out that the
house rules route this through the skill rather than raw MCP tools. If no
service is configured for them, show what the request looks like and explain how
it auto-enables once `.env` credentials are set.

### Checkpoint 3 — Hit a safety gate on purpose
Ask them to try `git push` and watch it get blocked by the workplace policy
(unless they've set `ALLOW_REMOTE_GIT=1`). Then have them try to reach a host
off the allowlist (e.g. `curl -sS --max-time 5 https://example.com`) and see the
egress wall refuse it. Make sure they understand *why* each was blocked.

### Checkpoint 4 — Do a real loop
Walk them through making a tiny change in `/workspace`, then ask you (or the
`sidekick` agent) to name a branch and write a commit message. Confirm the
branch name follows `branch-naming` and the message follows
`commit-conventions`. Do not push.

### Checkpoint 5 — Make it theirs
Show them where to add their own skill/agent/command: the user layer
(`~/.config/opencode/`, every repo, just them) or a repo's `.opencode/` (one
repo, checked in). Point them at `docs/ADDING_SKILLS.md`. Invite them to scaffold
a trivial command and see it load.

### Close
Recap what they tried, and remind them the `guide` agent (Tab) is always there
for questions. Encourage them to bring a real task next time.
