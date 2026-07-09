# Adding agents, skills, commands, and MCP servers

There are three places content can live. Pick the one that matches the scope
of your change.

| Scope                | Location                                  | Survives `docker compose down -v`? |
|----------------------|-------------------------------------------|-----|
| Everyone, every repo | The image (`opencode/bundle/`) — needs a rebuild | yes |
| You, every repo      | User layer volume (`oc_cfg_${SLUG}`)      | no, but easy to recreate |
| One repo             | `<repo>/.opencode/`                       | yes (it's in the repo)   |

## You, every repo (user layer)

The user-layer volume is mounted at `~/.config/opencode/` inside the container.
To make editing easy from the host, point `USER_LAYER_PATH` in `.env` to a
host directory; it gets bind-mounted in place of the named volume.

```
USER_LAYER_PATH=./user-layer
```

The wrapper at `scripts/opencode` notices the variable and automatically
layers `docker-compose.user-layer.yml` on top of the base compose file. If
you bring the stack up by hand, do the same:

```
docker compose -f docker-compose.yml -f docker-compose.user-layer.yml up -d
```

Then on the host:

```
mkdir -p ./user-layer/skills/my-skill
$EDITOR ./user-layer/skills/my-skill/SKILL.md
```

A skill is a *directory* containing a `SKILL.md`. The frontmatter must carry a
`name` that matches the directory (`my-skill` here) plus a `description`:

```yaml
---
name: my-skill
description: One line describing when this skill applies.
---
```

Agents and commands, by contrast, are flat `<name>.md` files in
`./user-layer/{agents,commands}/`. Restart the container and the new item shows
up.

## Disabling something the image ships

Two options.

1. Create a file with the same name in your user layer — your version wins.
2. Add it to `~/.config/opencode/disabled.yaml` (seeded on first boot):

   ```yaml
   disabled:
     agents:  [code-reviewer]
     skills:  [security-review]
     commands: []
     mcp:     []
   ```

The entrypoint reads this file and skips the matching bundle items when it
builds the merged config.

> Plugins are **not** controlled by this file — they ship OFF and are opted in
> via the `ENABLED_PLUGINS` variable in `.env`. See
> [`ADDING_PLUGINS.md`](ADDING_PLUGINS.md).

## Conditional skills (gate on a plugin or MCP)

A bundled skill that only makes sense when a specific plugin or MCP server is
active can declare that dependency, and the entrypoint links it **only when that
provider is up** — otherwise the skill is silently left out (and retracted on the
next boot if the provider is later turned off). This keeps the agent from seeing
a companion skill for tools that don't exist in the current configuration.

Drop a `.requires` file next to the skill's `SKILL.md`, one gate per line:

```
# opencode/bundle/skills/pty-sessions/.requires
plugin=opencode-pty
```

```
# opencode/bundle/skills/jira-fetch/.requires
mcp=jira
```

- **`plugin=<name>`** — linked only when `<name>` is listed in `ENABLED_PLUGINS`.
- **`mcp=<name>`** — linked only when that MCP server is actually up: its
  credentials are present in `.env` **and** it isn't force-disabled via
  `DISABLE_<SVC>_MCP=1`. This is the very same check that decides whether the
  server gets wired into `opencode.json`, so a skill can never advertise a
  service that isn't running.

Multiple lines are ANDed; an unknown key fails closed (the skill is skipped); no
`.requires` file means unconditional (the default). The gate applies to skills
only — agents and commands are flat `.md` files and can't carry one.

The shipped `*-fetch` skills use `mcp=…` so they appear only when their service
is configured, and `pty-sessions` uses `plugin=opencode-pty` so it appears only
when that plugin is enabled.

## Global house rules (`AGENTS.md`)

The bundle ships an `AGENTS.md` of workplace-wide instructions (e.g. "route
service access through the `*-fetch` skills, not the raw MCP tools"). The
entrypoint symlinks it to `~/.config/opencode/AGENTS.md`. OpenCode loads it
globally and *concatenates* it with any project-level `<repo>/AGENTS.md` and
user-level rules — it is additive, so it never clobbers your project's file.

To override the workplace rules, drop your own `AGENTS.md` into the user-layer
config dir (`~/.config/opencode/AGENTS.md`); a real file there shadows the
bundle symlink. To add repo-specific rules instead, just commit an `AGENTS.md`
to the repo root — both load together.

## TUI config and themes (`tui.json`)

The bundle ships `tui.json` (theme selection, keybinds, etc.) and a `themes/`
directory of custom theme JSON files, e.g. `themes/corp.json`. The entrypoint
symlinks both into `~/.config/opencode/` the same way as `AGENTS.md` — `tui.json`
directly, and each file under `themes/` treated like the `agents`/`skills`/
`commands`/`mcp` kinds (shadow-safe, and toggleable via `disabled.yaml`'s
`themes:` list).

To use your own theme instead, either drop a real `tui.json` into the user-layer
config dir (shadows the bundle symlink), or add a JSON file under
`~/.config/opencode/themes/` and point `tui.json`'s `theme` field at its
filename (without `.json`).

## One repo only

Standard OpenCode location: `<repo>/.opencode/`. This is checked in with the
repo so it travels with the codebase.

## Everyone, every repo (the bundle)

This requires changing the image. Open a PR against this repo adding files
under `opencode/bundle/`. The maintainer will cut a new tag.
