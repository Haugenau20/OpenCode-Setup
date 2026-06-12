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

## One repo only

Standard OpenCode location: `<repo>/.opencode/`. This is checked in with the
repo so it travels with the codebase.

## Everyone, every repo (the bundle)

This requires changing the image. Open a PR against this repo adding files
under `opencode/bundle/`. The maintainer will cut a new tag.
