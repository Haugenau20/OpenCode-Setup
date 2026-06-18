# Bundle

This directory is copied into the image at `/opt/opencode/bundle/` and
read-only at runtime. Anything you put here ships to every developer.

```
bundle/
  AGENTS.md  # global house rules, symlinked to ~/.config/opencode/AGENTS.md
  agents/    # opencode agent definitions  (<name>.md)
  skills/    # opencode skill definitions  (<name>/SKILL.md)
  commands/  # slash commands              (<name>.md)
  mcp/       # MCP server configs (e.g. RAG)
```

`AGENTS.md` is the workplace-wide instruction file. OpenCode loads it
globally and concatenates it with any project- or user-level `AGENTS.md`
(additive, not overriding). Keep it short — it loads in every session, every
repo. A developer who drops their own `~/.config/opencode/AGENTS.md` shadows
the bundle copy, same as any other bundle item.

Note the shapes opencode actually loads:

- **agents** and **commands** are flat markdown files: `<name>.md`. The agent
  name is the filename. Agent frontmatter needs `description` and (optionally)
  `mode: primary|subagent|all` — only `primary` agents show in the Tab agent
  switcher; `subagent`s are reached via `@<name>` or delegation.
- **skills** are *directories*: each skill is `skills/<name>/SKILL.md`, and the
  `SKILL.md` frontmatter must include a `name` field that matches the directory
  name. A flat `skills/<name>.md` is silently ignored by opencode.

At container start, each entry in these directories is symlinked into the
developer's user config at `~/.config/opencode/<kind>/<name>` (opencode follows
the symlinks). Developers can override a bundled item by creating an entry with
the same name in their user layer, or disable it via
`~/.config/opencode/disabled.yaml`.

See `docs/ADDING_SKILLS.md` for the full add/override/disable flow.
