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

Either way, keep the `after_create` hook empty and let the agent clone as its
first step. A clone in the hook would force a *repository* credential into this
container, which is the line worth holding.

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

### 6. `GITLAB_ALLOW_WRITE` — the MCP write surface

The GitLab MCP is read-only until you say otherwise. Unattended runs need more
than that: the agent has to open merge requests and answer review comments with
nobody at the keyboard. So:

```
GITLAB_ALLOW_WRITE=1
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

ALLOW_REMOTE_GIT=1
GIT_REMOTE_ALLOWLIST=gitlab.internal.example/my-group/my-project

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

### 5. Up

```
docker compose -f docker-compose.yml -f docker-compose.symphony.yml up -d
docker compose logs -f symphony
```

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

## Operating it

**Stop it.** `docker compose stop symphony` halts dispatch. In-flight items stay
in `in-progress/` and are recoverable — a restart re-dispatches them, because
whatever is in `in-progress/` is by definition what was live when it died.

**Retry a failure.** Move the file from `failed/` back to `todo/`, or reset
`attempts: 0` and `next_retry_at: null` and let the sweep take it.

**Give up on an item.** Move it to `cancelled/`.

**Accept work.** Review the MR, then move the item from `review/` to `done/`.
Nothing else moves it out of `review/` — that is the point of the gate.

**Audit.** `docker compose logs symphony` (structured JSON via pino), squid's
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

- **Bitbucket/GitLab MCPs are read-only.** The agent can read MR comments but
  cannot reply or merge, so `review/ → done/` is human-driven by construction.
  That is the intended shape for now, not a gap to close.
- **No cross-machine coordination.** On `file_queue` the queue is a directory on
  one host, and sharing it over a network filesystem would break the `rename(2)`
  atomicity argument. On `gitlab` there is no atomic claim at all, so two
  orchestrators against one project can double-dispatch. One orchestrator is the
  supported deployment either way.
- **Recovery re-runs side effects.** An item recovered from `in-progress/` is
  re-dispatched from the start rather than resuming its OpenCode session.
