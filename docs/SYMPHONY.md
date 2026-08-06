# Symphony: unattended runs from a folder queue

An opt-in mode. Instead of you driving one session, an orchestrator watches a
queue of work items and runs an agent per item, unattended, until each one is
ready for a human. It is off unless you add a compose overlay, and nothing about
the default stack changes while it is off.

This is a different way of working, not a new feature of the old one. Read the
safety section before the first run.

- **Orchestrator:** [`Haugenau20/symphony-queue`](https://github.com/Haugenau20/symphony-queue),
  vendored here at a pinned ref. Its own `docs/DESIGN.md` covers the queue
  semantics; this document covers running it inside this harness.
- **Lineage:** it implements the spec from
  [`openai/symphony`](https://github.com/openai/symphony), with the tracker
  replaced by a directory tree and Codex replaced by OpenCode.

## Two trackers: pick one

`tracker.kind` in `WORKFLOW.md` chooses where work items live.

| | `file_queue` | `gitlab` |
|---|---|---|
| Work item | a markdown file | a GitLab issue |
| State | the directory it sits in | a `symphony::<state>` label |
| Review surface | `ls symphony-queue/review/` | the issue page + its linked MR |
| Symphony needs | nothing — no token, no egress | a project token + squid |
| Atomic claim | yes, `rename(2)` is the lock | no (see below) |
| Setup | create a directory | create a project + labels |

**Start with `file_queue`.** It needs no GitLab project, no token and no
network, which makes stage 0 free — and stage 0 is where you find out whether
your model can hold an unattended loop at all.

**Move to `gitlab` for real work.** The review gate becomes a URL you can open
from a phone instead of an `ls` on one particular machine, merge requests link
themselves to issues, and the whole thing is visible to anyone with project
access.

One thing you give up: the file queue's claim is a `rename(2)`, which either
moves the file or fails, so two orchestrators cannot both claim an item. The
GitLab Issues API has no compare-and-swap, so that guarantee does not carry
over. With a single orchestrator — the intended deployment — it makes no
difference. With two polling one project, both can dispatch the same issue.

## The queue is the interface

```
symphony-queue/
├── todo/          # picked up in priority order
├── in-progress/   # claimed and running
├── review/        # the human gate: agent finished, waiting on you
├── done/          # you moved it here
├── failed/        # crashed; retried on a backoff until max_attempts
└── cancelled/     # you moved it here
```

This is the `file_queue` tracker's storage and only its storage. Under
`tracker.kind: gitlab` the state lives in issue labels, these directories hold
nothing, and neither the launcher nor the container creates them —
`./scripts/symphony status` shows the project instead, and `add` refuses rather
than writing a file nothing reads. `symphony-workspaces/` is created either way:
the agent gets one per item regardless of where the item came from.

One markdown file per item. **The directory it sits in is its state** — there is
no database and no status field. Moving a card is `mv`. Looking at the board is
`ls`. That is the whole reason there is no dashboard.

Claiming is a `rename(2)`, which is atomic within a filesystem, so the move
*is* the lock. It follows that all six directories must stay on one filesystem —
they are subdirectories of one root, so this holds unless you deliberately mount
one of them somewhere else.

An item looks like this:

```markdown
---
id: SYM-001
title: Fix token refresh race
priority: 2
labels: [bug]
blocked_by: []
branch: symphony/SYM-001-fix-token-refresh
jira: ABC-123
attempts: 0
next_retry_at: null
session_id: null
created_at: 2026-08-04T09:00:00Z
updated_at: 2026-08-04T09:00:00Z
---

What needs doing, in prose. This is the agent's brief.
```

`jira:` is informational — a pointer you can grep for. There is no Jira
integration and nothing is written back to it.

You create items by writing files. Drop one in `todo/` and it gets picked up on
the next poll.

## Safety: what actually contains this

The agent runs unattended, with an unrestricted bash tool, and it needs to push
branches and open merge requests to be useful at all. So be precise about which
of these is load-bearing.

### 1. The scoped token — this is the boundary

**Do not give symphony your personal access token.** A personal PAT carries your
whole GitLab identity: every group, every production repo you can reach. Nothing
in this container can claw that back, because the token *is* the authority.

Instead, prefer the narrowest thing that does the job:

1. **A project access token**, if symphony works one project — which is the
   normal case, since a GitLab project holds exactly one repository. Role
   **Developer**, scopes `api` + `write_repository`. This is the tightest
   option: one project, one repo, one issue tracker.
2. **A group access token** over a `symphony-sandbox` group, only once you want
   several repos under one credential. Same role and scopes.

Either way every other project returns 404. Not "denied" — invisible. A confused
agent, a hallucinated remote, a prompt injection out of an issue comment: all of
them hit a server-side authorization check that does not read English.

Then, all free and server-side, in the project or group settings:

- Protect `main`: **No one** may push; merge only via MR.
- Require at least one approval — the agent opens, a human merges.
- Developer, not Maintainer: it cannot change project settings or delete repos.
- Push rules (Premium), if you have them: branch regex `^symphony/.*`.

### 2. Credential absence removes capability

Each MCP server in this image auto-enables on credential presence. So the
symphony stack gets its own `.env` with **only** the sandbox GitLab token — no
`BITBUCKET_PAT`, no `JIRA_PAT`, no `CONFLUENCE_PAT`, no `JFROG_PAT`, no
`MFILES_PAT`. Those servers are then never wired into `opencode.json` at all.
Not disabled: absent.

### 3. Two tokens, neither able to do the other's job

This applies to `tracker.kind: gitlab`, and it is the reason a GitLab project is
a *better* containment story than the folder queue rather than a worse one.

| | Token | Role | Scope | Can push code? |
|---|---|---|---|---|
| **symphony** (`SYMPHONY_GITLAB_TOKEN`) | project access token | **Reporter** | `api` | **No** |
| **the agent** (`GITLAB_PAT`) | project access token | **Developer** | `api` + `write_repository` | Yes — that project only |

Symphony reads and writes issues. The agent pushes branches and opens MRs.
Neither can do the other's job, so a compromised orchestrator can vandalize
issue text and nothing else, and a prompt-injected agent cannot rewrite its own
work queue.

Be precise about what constrains what: **`api` is full API access for that
project** — there is no issues-only scope. It is the **Reporter role** that
stops symphony pushing code. Effective permission is scope × role, so get the
role right.

Both are *project* access tokens, so both are limited to one project. GitLab's
docs are explicit: a project access token *"can access only its project, and you
cannot use project access tokens to access resources in other projects, or to
create other group, project, or personal access tokens."*

### 4. Symphony holds nothing (file queue) or one weak token (gitlab)

On `file_queue`, symphony has no egress, no credentials and no git remote at
all. It talks to the opencode server and moves files.

On `gitlab` it needs to reach the API, so it gets the Reporter token above and
`SYMPHONY_HTTP_PROXY=http://squid:3128`. Both its networks are `internal: true`,
so squid remains the only way out and the existing
`squid/allowlist.d/30-gitlab.conf` entry is all it can reach. That is a real
reduction from "holds nothing", and the Reporter role is the compensation.

Two things have to be true for that proxy to work at all, and both were missed
the first time:

- **Symphony's code has to use the proxy explicitly.** Node's global `fetch` is
  undici, and **undici ignores `HTTP_PROXY`/`HTTPS_PROXY`**. Setting the
  variable is not enough — something has to build a `ProxyAgent` from it. Every
  MCP server in the opencode image does (`opencode/mcp-servers/_lib/common.js`);
  symphony-queue's GitLab tracker did not, so the first live run failed on its
  first API call with `TypeError: fetch failed` while the proxy sat unused.
  Fixed in symphony-queue — if you are pinned to a `SYMPHONY_REF` older than
  that fix, this is the bug you will hit.
- **Node has to trust your CA.** `update-ca-certificates` in the image populates
  the *system* store, and Node ships its own bundle and does not read the system
  one. `NODE_EXTRA_CA_CERTS` in `symphony/Dockerfile` is what bridges that. The
  symptom without it is TLS failing from Node while `curl` in the same container
  succeeds.

The quickest way to tell these apart from inside the container — `curl` honours
the proxy variables, Node does not:

```
docker exec opencode-symphony-<slug> \
  curl -sS -o /dev/null -w '%{http_code}\n' https://<your-gitlab>/api/v4/version
docker exec opencode-symphony-<slug> \
  node -e 'fetch("https://<your-gitlab>/api/v4/version").then(r=>console.log(r.status)).catch(e=>console.log(e.cause?.code??e.message))'
```

`curl` working while Node fails is the proxy problem. Both failing on TLS is the
CA problem. Both failing to connect is squid's allowlist — add your host under
`extra-allowlist.d/`.

Either way, keep the `after_create` hook empty and let the agent clone as its
first step. A clone in the hook would force a *repository* credential into this
container, which is the line worth holding.

That is only half a decision, though — see [The agent clones its own
workspace](#the-agent-clones-its-own-workspace) for the other half, which is
making sure the prompt actually tells it to.

### 5. `GIT_REMOTE_ALLOWLIST` — defence in depth, not a boundary

`ALLOW_REMOTE_GIT=1` is required for symphony, and it is binary: once on, every
remote is reachable. `GIT_REMOTE_ALLOWLIST` narrows the destination:

```
ALLOW_REMOTE_GIT=1
GIT_REMOTE_ALLOWLIST=gitlab.internal.example/symphony-sandbox/
```

Whitespace- or comma-separated `host/path` prefixes, matched on a path-segment
boundary, so `…/symphony-sandbox` is not satisfied by `…/symphony-sandbox-evil`.
It resolves named remotes through `git remote get-url`, normalizes scp-style
`git@host:path`, ignores ports and userinfo, and honours `-C` / `--git-dir` so
the remote is read from the repo the command will actually act on.

**It is not a security boundary.** The agent has bash and can call
`/usr/bin/git` directly, past the PATH shim. Its job is to turn a mistake — a
stale branch config, a pasted URL, a hallucinated remote — into a legible local
error instead of a confusing 403. Do not let it substitute for §1.

### 6. `ALLOW_GITLAB_WRITE` — the MCP write surface

The GitLab MCP is read-only until you say otherwise. Unattended runs need more
than that: the agent has to open merge requests and answer review comments with
nobody at the keyboard. So:

```
ALLOW_GITLAB_WRITE=1
GITLAB_WRITE_PROJECTS=mygroup/my-sandbox-project
```

With the switch off the write tools are not offered to the model at all. With it
on, it gains: `create_merge_request`, `update_merge_request`, `create_mr_note`,
`create_issue`, `create_issue_note`, `update_issue_note`. `GITLAB_WRITE_PROJECTS`
narrows that to specific projects, prefix-matched on a path-segment boundary —
the same rule `GIT_REMOTE_ALLOWLIST` uses, so there is one thing to learn.

Gated twice, because hiding a tool from `tools/list` is not enforcement: the
tools are not listed, **and** every write handler re-checks before acting.

**What stays impossible even at `=1`:** there is no tool to set an issue's
labels, close or reopen an issue, or merge an MR. In this workflow the
`symphony::` label *is* the state and the orchestrator owns every transition. An
agent that could relabel its own issue could mark its own work reviewed, or file
itself new `symphony::todo` work forever. `create_issue` refuses labels in that
namespace outright, so a follow-up the agent files arrives unlabelled and a
human decides whether it joins the queue.

Same caveat as always: defence in depth, not a boundary. The agent has a shell
and a token and can `curl` the API. The boundary is §1 and §3 — the token's
project scope and its role.

### 7. Tracker content is untrusted input

The agent writes its workpad into the same file the orchestrator parses, so
front matter is agent-influenced by construction. The tracker validates every
field, refuses ids that are not `^[A-Za-z0-9][A-Za-z0-9._-]*$`, resolves every
path through a containment check, and never interpolates a front-matter value
into a shell command or a git URL.

The same holds on GitLab, more so: an issue description or comment is writable
by the agent *and* by anyone with project access. Treat both as hostile input.

The corollary for you: **`WORKFLOW.md` is trusted config and is mounted
read-only.** It drives the hooks. Never template a hook from item content.

## The agent clones its own workspace

Symphony creates an **empty** directory per item at
`symphony-workspaces/<id>/` and hands the agent its path. It does not put
anything in it. The reason is §4 above: a clone on symphony's side needs a
repository credential, and symphony is the container that deliberately does not
have one.

So the clone is the agent's first step, and **the workflow prompt has to say
so** — an empty directory and no instruction is just an agent with no code.
Both `WORKFLOW.*.example` files carry a "First: clone the project" section for
this. Edit the URL in it to match your project.

The URL lives in `WORKFLOW.md` and nowhere else. That file is trusted config,
mounted read-only. An issue description is not: it is writable by the agent and
by anyone with project access, so "clone from … first" inside an issue is an
attack, not an instruction. The prompt says this to the agent in as many words,
because the untrusted-input rule is only as good as the agent's willingness to
follow it.

Two lines duplicate `tracker.project_id` as a result. That is deliberate: the
clone URL has to be somewhere the agent reads, and this is the only file it can
safely come from. `./scripts/symphony check` cross-checks the two, along with
`GIT_REMOTE_ALLOWLIST` and `GITLAB_WRITE_PROJECTS`, so a mismatch is caught
before a run rather than during one.

## What `stall_timeout_ms` actually measures

Today it is a **run** timeout, not a stall detector. Symphony stamps the moment
a run starts and — at the pinned `SYMPHONY_REF` — nothing updates that stamp
while the agent works, so a run is killed once it has simply been *alive* this
long, however much progress it is making.

The upstream default is 300000 (5 minutes). That is fine for a stage-0
hello-world item and far too short for anything that clones a repository:
**raise it to 1800000 (30 minutes) before the first real run.** The GitLab
example already does.

Newer symphony-queue turns it into a real stall detector by feeding agent
activity — turn boundaries plus the session's SDK event stream — into the
reference timestamp, at which point the number means "silent for this long"
and 30 minutes is generous rather than tight. Check the log: a
`stall_detected` line carrying `sawActivity: false` means the event stream
never connected and the timeout has quietly gone back to being a run timeout.

## What a turn is

**One session, many prompts — not one agent per turn.** Symphony creates a
single OpenCode session per item and prompts it repeatedly:

| | |
|---|---|
| Turn 1 | the rendered `WORKFLOW.md` prompt body |
| Turns 2…`max_turns` | `agent.continuation_guidance`, into the *same* session |

The conversation accumulates, so turn 7 still has turns 1–6 in context.
`max_turns: 10` is ten sequential prompts to one agent, not ten agents.

**And the loop had no exit but exhaustion.** Its only early-stop test was "has
the item left its active states?" — but symphony owns that label and does not
move it until the run is over, and the agent is forbidden from relabelling its
own issue. So the answer was always "still active", every time.

An agent that finished at turn 3 of 10 got seven more "the work is not
finished, resume, focus on the remaining work" prompts, holding a live
credential and a pushed branch. The cheapest ways to fill an empty turn are
amending commits, force-pushing, opening a second merge request, or rewriting
work that was already correct — so raising `max_turns` made this worse, not
better.

`agent.completion_marker` (default `SYMPHONY_DONE`) is the fix: the agent emits
it on a line of its own and the run ends there. Whole-line, not substring —
agents narrate their own instructions, and "I'll reply with SYMPHONY_DONE once
the MR is open" must not be read as the declaration itself. Your workflow prompt
has to *tell* the agent to emit it; the GitLab example does, in rule 10 and in
the continuation guidance.

Treat `max_turns` as a **ceiling, not a budget**. With a working marker a
generous ceiling costs nothing on a run that finishes early.

## `review` means the agent stopped, not that it finished

Symphony moves an item to `review` on a **clean exit** — the agent's turn loop
returned without throwing. Running out of `max_turns` is a clean exit. So an
item can arrive in `symphony::review` with no merge request, no branch, and no
work at all, and nothing in symphony's log will say so: you will see
`turnsCompleted: N` against your `max_turns: N` and `state_transitioned_on_exit`.

The log now says which happened outright. `agent_run_completed` carries a
`stopReason`:

| `stopReason` | what it means |
|---|---|
| `completed` | the agent emitted the completion marker. It thinks it is done. |
| `max_turns` | **interrupted** mid-task. Also logs `agent_run_hit_max_turns` at warn. |
| `issue_inactive` | a human moved the label to a terminal state mid-run. |

`max_turns` with no merge request is the case worth chasing. On an older
`SYMPHONY_REF` there is no `stopReason`, and the tell is `turnsCompleted`
reaching `max_turns` exactly.

Three levers, in the order they matter:

- **`agent.completion_marker`.** Without it the run *always* uses every turn —
  see above. This is the one that makes the other two safe.
- **`agent.continuation_guidance`.** The nudge sent at the start of every turn
  after the first. The built-in default is tracker-neutral and cannot name your
  finishing step, so name it — the GitLab example spends most of its text on
  "you are not done until the MR exists" and on what to do with one turn left.
- **`max_turns`.** A ceiling. Clone, implement, commit, push and open an MR does
  not fit in 3 for a non-frontier model; 8–12 is right once a run has worked
  end to end, and with a working marker a generous ceiling costs nothing.

When an MR does not appear, symphony's log cannot tell you why; it only knows
the agent stopped. The evidence is in three places: the workspace on the host
(`git log`, `git status -sb`, `git ls-remote --heads origin 'symphony/*'` —
which separates "never cloned" from "committed but never pushed" from "pushed
but no MR"), the issue's workpad comment, and the OpenCode session named by
`sessionId` in the log.

## Workspaces are reclaimed, eventually

Clones are not small and they accumulate. Symphony deletes the workspace of any
item that has reached a **terminal** state — `symphony::done` or
`symphony::cancelled`, `done/` or `cancelled/`.

Terminal is a human decision and nothing notifies symphony of it, so this is
driven by the poll: newer symphony-queue sweeps on every tick, older builds
only at process start (meaning a long-lived orchestrator reclaimed nothing
until you restarted it). Either way the trigger is the same, and it is the same
trigger as everything else in this design: **`review/ → done/` is yours to
make.** An item parked in `review/` keeps its clone, by design — that is what
you review.

Nothing watches merge-request state. A merged MR does not move an item to
`done` on its own.

## Setup

### 1. A separate stack

Symphony wants its own scaffold clone and its own `.env` — different
`PROJECT_SLUG`, different `OPENCODE_PORT`, and critically a different, smaller
set of credentials.

```
./scripts/new-project.sh symphony ~/code/symphony-sandbox-repo
cd ../OpenCode-Setup-symphony
$EDITOR .env
```

### 2. `.env`

```
PROJECT_SLUG=symphony
OPENCODE_PORT=4097

LLM_API_BASE=https://llm.internal.example/v1
LLM_API_KEY=<yours>

# The AGENT's token: project (or group) access token, Developer role.
# NOT your personal PAT.
GITLAB_BASE_URL=https://gitlab.internal.example
GITLAB_USER=<you>
GITLAB_PAT=<project access token, Developer, api+write_repository>

# Only for tracker.kind: gitlab — SYMPHONY's token. Reporter role: it can
# read/write issues on this one project and cannot push code. A separate
# token from GITLAB_PAT above, deliberately.
SYMPHONY_GITLAB_TOKEN=<project access token, Reporter, api>
SYMPHONY_HTTP_PROXY=http://squid:3128

# Leave every other *_PAT blank.

# Two gates, two planes: git (enforced by opencode/git-guard) and the API
# (enforced by the MCP write gate). They are read by different processes, so
# they cannot check each other — `./scripts/symphony check` does that for them.
ALLOW_REMOTE_GIT=1
GIT_REMOTE_ALLOWLIST=gitlab.internal.example/my-group/my-project
ALLOW_GITLAB_WRITE=1
GITLAB_WRITE_PROJECTS=my-group/my-project

SYMPHONY_REF=v0.1.0
SYMPHONY_QUEUE_PATH=./symphony-queue
SYMPHONY_WORKSPACES_PATH=./symphony-workspaces
SYMPHONY_CONFIG_PATH=./symphony
```

### 3. Trim the allowlist

The symphony stack does not need Confluence, M-Files, Jira or JFrog. Drop a file
into `extra-allowlist.d/` covering only the LLM endpoint and GitLab, and remove
the rest — reducing the surface before credentials even come into it.

### 4. Workflow

```
cp symphony/WORKFLOW.md.example symphony/WORKFLOW.md          # file queue
cp symphony/WORKFLOW.gitlab.md.example symphony/WORKFLOW.md   # GitLab issues
$EDITOR symphony/WORKFLOW.md
```

For the GitLab tracker, create the state labels on the project first —
`symphony::todo`, `symphony::in-progress`, `symphony::review`,
`symphony::done`, `symphony::failed`, `symphony::cancelled`. On Premium they
are scoped labels and mutually exclusive in the UI; on Free they are ordinary
labels and symphony enforces exclusivity itself by rewriting the whole label
set on every transition. Nothing behaves differently.

An issue with no `symphony::` label is not symphony's and is ignored. That is
how you keep an ordinary backlog in the same project: work only becomes
symphony's when you label it `symphony::todo`.

Front matter is config, the body is the agent's prompt template (Liquid). Start
with `max_concurrent_agents: 1` and `max_turns: 3`.

Three things in the copied file need your attention before the first run:
`tracker.base_url` and `tracker.project_id` in the front matter, the clone URL
in the prompt's "First: clone the project" section, and `stall_timeout_ms` —
which measures the wrong thing at the pinned ref and needs to be generous
because of it. Both are explained above.

### 5. Up

Use the launcher — it composes the right `-f` flags and refuses to start on a
misconfiguration:

```
./scripts/symphony check     # preflight only, changes nothing
./scripts/symphony up        # start
./scripts/symphony logs      # follow the orchestrator
```

Other verbs: `status` (per-directory queue counts), `watch` (status on a timer),
`add "..."` (queue an item without hand-writing front matter), `stop`, `down`,
`build`.

`check` is worth running on its own after any `.env` edit. It refuses outright
on a missing `WORKFLOW.md`, a GitLab tracker with no token or no egress, or a
workspaces mount pointing at your real repo — and warns on the quieter
mistakes: one token used for both symphony and the agent, remote git on with no
`GIT_REMOTE_ALLOWLIST`, writes enabled with no `GITLAB_WRITE_PROJECTS`, or more
than one agent at a time before you have watched a full run.

## Rolling this out

Do not start at the end. Each stage answers a question, and the cheap ones come
first.

**Stage 0 — can the model do this at all?** `ALLOW_REMOTE_GIT=0`, a throwaway
repo, one item. The agent can commit locally and *cannot push*. Zero remote
risk, and it answers the only question that matters: does your model hold an
unattended multi-turn loop, or does it derail at turn four? This stack runs
against an internal endpoint with Qwen/MiniMax/Gemma — models Symphony was not
designed around, and the README already documents Qwen rejecting extra injected
tooling. If the answer here is no, nothing downstream is worth building.

**Stage 1 — one item, one agent, real remote.** Sandbox group token,
`ALLOW_REMOTE_GIT=1`, `max_concurrent_agents: 1`, `max_turns: 3`. Watch it push
a branch and open an MR.

**Stage 2 — widen slowly.** A group token over two or three low-stakes real
repos. Protected `main`, approvals required. Raise `max_turns` before you raise
concurrency: turns tell you whether the model can finish, concurrency only
multiplies whatever it already does.

**Production repos.** Only via a group token scoped to exactly them, Developer
role, protected branches. Never a personal PAT, at any stage.

## The first run against a real GitLab project

Nothing here has touched a live GitLab API — the tracker and all six write
tools are unit-tested against mocks. So do this once, deliberately, against a
project you would not mind losing.

**1. A sandbox project.** A new GitLab project with a small real repository in
it. In *Settings → Repository → Protected branches*, protect `main`: **No one**
may push, merge via MR only. That single setting is what makes the rest of this
recoverable.

**2. Six labels**, in *Project information → Labels*:

```
symphony::todo  symphony::in-progress  symphony::review
symphony::done  symphony::failed       symphony::cancelled
```

An issue carrying none of them is not symphony's and is ignored, which is how
an ordinary backlog lives in the same project. On Premium these are scoped
labels and mutually exclusive in the UI; on Free they are ordinary labels and
symphony enforces exclusivity itself by rewriting the whole set on every
transition. Nothing behaves differently.

**3. Two project access tokens**, in *Settings → Access tokens*. Not one used
twice — the split is the containment (§3 above), and the preflight warns if
they match:

| Token | Role | Scopes | Goes in |
|---|---|---|---|
| symphony's | **Reporter** | `api` | `SYMPHONY_GITLAB_TOKEN` |
| the agent's | **Developer** | `api`, `write_repository` | `GITLAB_PAT` |

**4. `.env`**, on top of the base config in Setup above:

```
ALLOW_REMOTE_GIT=1
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject
ALLOW_GITLAB_WRITE=1
GITLAB_WRITE_PROJECTS=mygroup/myproject
SYMPHONY_HTTP_PROXY=http://squid:3128
```

Both allowlists, both formats. `check` cross-checks them against each other and
against the tracker's project, so a typo in one is caught before the run.

**5. `WORKFLOW.md`:**

```
cp symphony/WORKFLOW.gitlab.md.example symphony/WORKFLOW.md
```

Set `tracker.base_url` and `tracker.project_id`, and **edit the clone URL in
the "First: clone the project" section to match**. Keep
`max_concurrent_agents: 1` and `max_turns` low, and leave `stall_timeout_ms` at
the 1800000 the example ships with.

**6. Go.**

```
./scripts/symphony check     # fix everything it complains about first
./scripts/symphony up
./scripts/symphony logs      # leave this running
```

Then create an issue, label it `symphony::todo`, and watch.

**What to expect when it breaks.** In rough order of likelihood:

- **`TypeError: fetch failed` on the very first poll**, before any issue is
  picked up. Symphony cannot reach GitLab: proxy, CA, or squid allowlist. See
  §4 above for the three-way split and the two commands that tell them apart.
  On a `SYMPHONY_REF` new enough to carry the fix, the log says which — look for
  `gitlab_tracker_ready` with `viaProxy: true` at startup, and a connection
  error naming an errno rather than "fetch failed".
- **The clone fails.** Wrong URL in `WORKFLOW.md`, or a destination
  `GIT_REMOTE_ALLOWLIST` does not admit. `check` catches both; if it did not,
  the agent's first bash command is where to look.
- **The run is killed after a few minutes.** `stall_timeout_ms` too low for
  work that clones a repository. Look for `stall_detected` in the log.
- **403s.** Check which token: symphony's Reporter token *cannot* open merge
  requests, and that is correct — the agent's Developer token does that. A 403
  on merge is also expected; merging is a human decision.
- **Nothing is picked up at all.** Label names must match `label_prefix`
  exactly, `::` and all.

## Operating it

**Stop it.** `./scripts/symphony stop` halts dispatch. In-flight items stay
in `in-progress/` and are recoverable — a restart re-dispatches them, because
whatever is in `in-progress/` is by definition what was live when it died.

**Retry a failure.** Move the file from `failed/` back to `todo/`, or reset
`attempts: 0` and `next_retry_at: null` and let the sweep take it.

**Give up on an item.** Move it to `cancelled/`.

**Accept work.** Review the MR, then move the item from `review/` to `done/`.
Nothing else moves it out of `review/` — that is the point of the gate.

**Audit.** `./scripts/symphony logs` (structured JSON via pino), squid's
deny log, and GitLab's audit events attributed to the sandbox token. The
workpad in each item file is the per-item history.

## Developing symphony-queue itself

Add the dev overlay to bind-mount a host checkout over the baked-in build:

```
export SYMPHONY_SRC_PATH=~/code/symphony-queue
cd $SYMPHONY_SRC_PATH && npm ci && npm run build
cd -
docker compose -f docker-compose.yml \
               -f docker-compose.symphony.yml \
               -f docker-compose.symphony-dev.yml up -d
```

Rebuild on the host after each change and restart the container. Turn it off
when you are done — a bind mount means "whatever is there right now", which is
exactly what the `SYMPHONY_REF` pin exists to avoid.

To ship a change: cut a tag in `symphony-queue`, bump `SYMPHONY_REF`, rebuild.

## Known limits

- **Never run against a real GitLab instance yet.** `GitLabTracker` and all six
  MCP write tools are unit-tested against mocks and have not touched a live
  API. Assume the first run finds bugs; see the checklist above for where to
  look.
- **The agent cannot close the loop.** With `ALLOW_GITLAB_WRITE=1` it can open
  merge requests and answer review comments, but there is deliberately no tool
  to relabel an issue, close one, or merge an MR — the `symphony::` namespace
  is workflow state and the orchestrator owns every transition. So
  `review → done` is human-driven by construction. That is the intended shape,
  not a gap to close.
- **Nothing watches merge-request state.** An MR being merged does not move its
  item to `done`, and therefore does not reclaim its workspace. Polling MR
  state would need the API token and is a separate change.
- **Recovery re-runs side effects.** An item recovered from `in-progress/` is
  re-dispatched from the start rather than resuming its OpenCode session. The
  `session_id` field exists in the schema for a future resume path and is
  unused.
- **No cross-machine coordination.** On `file_queue` the queue is a directory on
  one host, and sharing it over a network filesystem would break the `rename(2)`
  atomicity argument. On `gitlab` there is no atomic claim at all, so two
  orchestrators against one project can double-dispatch. One orchestrator is the
  supported deployment either way.
