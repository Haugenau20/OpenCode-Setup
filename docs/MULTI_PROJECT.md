# Running several projects from one checkout

One clone of this repo runs any number of stacks. This document is the contract:
what a launcher has to set for a project to come up correctly, and why each part
is shaped the way it is.

`scripts/opencode` and `scripts/symphony` implement it, but they are maintainer
tooling. The user-facing launcher is
[`Opencode-Launcher`](https://github.com/Haugenau20/Opencode-Launcher), and it
has to set the same three variables to get the same result. Everything below is
written for whoever does that port.

## Why not one stack for several projects

The obvious design — one opencode container, several repos mounted — is the one
to avoid, and the reason is the credential model rather than anything technical.

`docs/SYMPHONY.md` §1–§3 puts containment on **scoped tokens**: the agent holds
a project access token (Developer), symphony holds a separate one (Reporter),
and §2 makes credential *absence* the thing that removes capability. Merge
projects A and B into one container and the agent working A holds B's push
token. That collapses into "one credential that reaches everything", which is
the personal-PAT posture the whole document argues against.

Upstream agrees by construction: symphony-queue's `WorkflowStore` takes a single
workflow path and `main.ts` builds exactly one tracker. One orchestrator is one
project.

So the goal is not "one stack, many projects". It is **make a stack per project
cheap** — one checkout, one set of images, N configurations.

## The contract

Three variables. Set them and a stack is that project's; leave them and you get
the single-project behaviour that existed before any of this.

### `PROJECT_ENV_FILE` — per-project container environment

```yaml
    env_file:
      - .env
      - path: ${PROJECT_ENV_FILE:-.env}
        required: false
```

`env_file` is last-wins, so the order **is** the mechanism. The root `.env`
holds what every project shares; the file named here holds what differs.

This is the one piece that cannot be done any other way. `--env-file` drives
compose's `${VAR}` *interpolation* — it does not put anything in a container.
Only an `env_file:` directive does that, and it takes a literal path. Without
this layer a launcher can vary ports and paths but every project still gets one
shared set of credentials.

A per-project value may also blank an inherited one:

```
CONFLUENCE_PAT=
```

Empty is how every MCP server in this image reads "off", so blanking keeps that
server out of the stack entirely — absent, not disabled. That is §2 of
`docs/SYMPHONY.md`, expressed per project.

Defaulting to `.env` means the file is simply read twice when no project is
selected, which changes nothing. `required: false` keeps a project that has no
env file from being an error.

### `EXTRA_ALLOWLIST_PATH` — per-project egress surface

```yaml
      - ${EXTRA_ALLOWLIST_PATH:-./extra-allowlist.d}:/etc/squid/extra-allowlist.d:ro,z
```

`docs/SYMPHONY.md` §3 tells you to trim a symphony stack's allowlist to the LLM
endpoint and GitLab. That was not expressible while every stack bind-mounted one
shared directory. Point this at the project's own directory to give one stack a
different egress surface; leave it and every stack shares the checkout-wide one.

Treat it as opt-in — only set it when the project actually ships an allowlist
directory, or you will mount an empty one over a shared list that was working.

### `PROJECT_SLUG` plus `-p opencode-<slug>` — identity

`PROJECT_SLUG` already suffixed every container name and volume name before any
of this. What was missing is the **compose project name**:

```
docker compose -p "opencode-${PROJECT_SLUG}" ...
```

Container names being distinct is not enough. Without `-p`, compose considers
all these containers part of one project and `up` on one stack treats the
other's containers as orphans to remove.

## The rest is paths

Everything else is an ordinary setting that a launcher points at a per-project
location. None of it needs a compose change — the overlay was already fully
parameterised:

| Variable | What it holds |
|---|---|
| `REPO_PATH` | the repo bind-mounted at `/workspace` |
| `OPENCODE_PORT` | the host port (its viewer port is `1<port>`) |
| `SYMPHONY_CONFIG_PATH` | directory holding `WORKFLOW.md`, mounted `ro` at `/config` |
| `SYMPHONY_QUEUE_PATH` | the six file-queue state directories |
| `SYMPHONY_WORKSPACES_PATH` | per-item agent workspaces |

### Two path rules that are not obvious

**The config directory must not contain an agent env file.** It is bind-mounted
into the symphony container, which is supposed to hold the Reporter token and
nothing else. Put `WORKFLOW.md` in a subdirectory rather than beside the
project's `.env`. `./scripts/symphony check` refuses to start on this.

(`symphony/.env` sitting in the default config directory is fine — that is
symphony's own token in symphony's own container, crossing no boundary.)

**Per-project paths must outrank shared defaults.** `symphony/.env.example`
ships concrete paths (`./symphony-queue`, `./symphony-workspaces`). If a project
inherits those, every project lands on one queue — and two orchestrators
claiming one item is exactly what the `rename(2)` argument in
`docs/SYMPHONY.md` assumes cannot happen. It fails silently, which is what makes
it worth designing against rather than documenting around.

`scripts/symphony` resolves this by ordering the layers:

```
.env                          shared,      agent-visible
symphony/.env                 shared,      launcher-only
  → derive per-project paths from the project directory
projects/<slug>/.env          per-project, agent-visible
projects/<slug>/symphony.env  per-project, launcher-only
```

The derivation sits **after** the shared files, so a shared default cannot alias
two projects together, and **before** the project's own files, so an explicit
per-project value still wins.

## The layout this repo uses

Not part of the contract — a launcher may store configuration however it likes,
as long as it ends up setting the variables above. This is what the maintainer
scripts do:

```
projects/<slug>/
├── .env            → PROJECT_ENV_FILE
├── symphony.env      (launcher-only; never named by any env_file: directive)
├── config/         → SYMPHONY_CONFIG_PATH
│   └── WORKFLOW.md
├── queue/          → SYMPHONY_QUEUE_PATH
└── workspaces/     → SYMPHONY_WORKSPACES_PATH
```

```
./scripts/new-project.sh <slug> [repo-path]
./scripts/opencode -p <slug>
./scripts/symphony -p <slug> check
./scripts/symphony projects          # what exists, on which port, up or not
./scripts/symphony -p <slug> config  # the fully resolved stack
```

## Notes for the Opencode-Launcher port

The launcher already solved most of this shape for the interactive case, and the
existing pieces map over directly:

- `derive_slug`, `resolve_project_port` and `port_pair_free` in `lib/project.sh`
  need no change. The viewer-port pairing matters here too — `oc-publish` binds
  both, so a free base port with a taken viewer port still fails to come up.
- `write_project_env` generates `.envs/<slug>.env` as `cat "$ENV_FILE"` plus
  per-project settings. **Point `PROJECT_ENV_FILE` at exactly that file.** The
  generated-file model and the layered-file model converge here: what compose
  needs is one path to a file whose per-project values come last, and a
  concatenation already satisfies that.
- `--project-directory` is already passed, so relative paths in the compose
  files keep resolving against the repo root. `PROJECT_ENV_FILE` is resolved the
  same way, so a repo-root-relative path is what to write.

One thing does need care. The launcher's model is *shared secrets, per-project
interpolation* — one `.env` holding credentials every project gets. That is
correct for interactive multi-repo work and wrong for symphony, where credential
absence is a capability control. If the launcher grows symphony support, the
per-project layer has to be able to **subtract** credentials, not only add
settings — which means writing explicit blank assignments (`CONFLUENCE_PAT=`)
into the generated file, since a key that is merely missing inherits.

The safest split, and the one worth aiming at: keep the shared file free of
project-scoped secrets entirely (base URLs, image tags, UID/GID, and
`LLM_API_KEY`, which is per-developer rather than per-project), and let every
`*_PAT` live in the project layer. Then concatenation is safe by construction
instead of safe by remembering to blank things.
