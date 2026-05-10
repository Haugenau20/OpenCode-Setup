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
USER_LAYER_PATH=~/.opencode-work
```

Then on the host:

```
mkdir -p ~/.opencode-work/skills
$EDITOR ~/.opencode-work/skills/my-skill.md
```

Restart the container (or run `opencode reload` inside it) and the new skill
shows up.

## Disabling something the image ships

Two options.

1. Create a file with the same name in your user layer — your version wins.
2. Add it to `~/.opencode-work/disabled.yaml`:

   ```yaml
   disabled:
     agents:  [code-reviewer]
     skills:  [security-review]
     commands: []
     mcp:     []
   ```

The entrypoint reads this file and skips the matching bundle items when it
builds the merged config.

## One repo only

Standard OpenCode location: `<repo>/.opencode/`. This is checked in with the
repo so it travels with the codebase.

## Everyone, every repo (the bundle)

This requires changing the image. Open a PR against this repo adding files
under `opencode/bundle/`. The maintainer will cut a new tag.
