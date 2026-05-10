# Bundle

This directory is copied into the image at `/opt/opencode/bundle/` and
read-only at runtime. Anything you put here ships to every developer.

```
bundle/
  agents/    # opencode agent definitions
  skills/    # opencode skill definitions
  commands/  # slash commands
  mcp/       # MCP server configs (e.g. RAG)
```

At container start, each file in these directories is symlinked into the
developer's user config at `~/.config/opencode/<kind>/<name>`. Developers can
override a bundled item by creating a file with the same name in their user
layer, or disable it via `~/.config/opencode/disabled.yaml`.

See `docs/ADDING_SKILLS.md` for the full add/override/disable flow.
