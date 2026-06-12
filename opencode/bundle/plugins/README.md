# Bundled plugins

Unlike `agents/`, `skills/`, and `commands/` (which are plain files checked into
this directory), **plugins are built at image-build time**, not stored here. The
real plugin code — often with a `node_modules/` — is cloned and vendored by the
`plugins-build` stage in [`../Dockerfile`](../Dockerfile) and lands at
`/opt/opencode/bundle/plugins/<name>/` inside the image. This file is the only
thing in `plugins/` that ships from the repo.

## Why plugins are different

- **Opt-in / default-OFF, env-var controlled.** Agents/skills/commands ship
  enabled; plugins ship disabled. A developer turns one on **only** via the
  `ENABLED_PLUGINS` list in `.env` (space/comma-separated). `disabled.yaml` does
  *not* control plugins — it persists in a volume and would silently override
  `.env`. The entrypoint rebuilds the plugin symlinks to match `ENABLED_PLUGINS`
  on every boot. `/plugins` shows the live state.
- **Loaded by symlink, not by the `plugin` array.** OpenCode auto-scans
  `plugin/*.{ts,js}` in each config dir and imports the files directly (it
  follows symlinks; verified in the 1.16.2 and 1.17.3 binaries). The entrypoint
  symlinks the entry files of *enabled*
  plugins into `~/.config/opencode/plugin/`. We deliberately do **not** put
  entries in `opencode.json`'s `plugin` array — that path makes OpenCode/Bun
  run a network install, which the egress lock blocks. `policy.yaml` also sets
  `BUN_CONFIG_SKIP_INSTALL_PACKAGES=true` so no startup install is attempted;
  resolution falls back to each plugin's vendored `node_modules`.

## Layout the entrypoint expects

Each baked plugin is a directory under `/opt/opencode/bundle/plugins/<name>/`
containing an **`entries`** manifest — one `linkname=relative/entry/path` per
line. The entrypoint symlinks `<name>`'s entries into the user config:

```
/opt/opencode/bundle/plugins/dcp/
  entries            # "dcp.js=dist/index.js"
  dist/index.js      # the entry the symlink points at
  node_modules/      # vendored runtime deps, resolved relative to dist/
  seed/dcp.jsonc     # optional: copied to ~/.config/opencode/ on enable
```

`# `-prefixed lines in `entries` are ignored. A plugin may declare multiple
entries (e.g. `opencode-workspace` ships two). Imports resolve from the entry
file's **real** path (Node/Bun resolves symlinks), so a vendored `node_modules`
sitting next to the real files is found automatically.

## Adding or updating a plugin

Edit the `plugins-build` stage in `../Dockerfile`: clone at a pinned ref, build
if needed, vendor runtime deps, write an `entries` manifest, and `cp` the result
into `/staging/plugins/<name>/`. Then list the new name in the `.env.example`
`ENABLED_PLUGINS` comment, the description map in `./commands/plugins.md`, and
the table below. Pin by tag or commit SHA — never a moving branch — and re-test
the load on every bump. See
[`../../docs/ADDING_PLUGINS.md`](../../docs/ADDING_PLUGINS.md).

## Currently baked

| Name | What it is | Default |
|------|------------|---------|
| `superpowers` | Skills library (brainstorming, writing-plans, systematic-debugging, TDD, code review). Zero deps, zero runtime egress. | OFF |
| `dcp` | Dynamic context pruning — trims stale tool output from the context window to save tokens. | OFF |
| `opencode-workspace` | `plan_save`/`plan_read` tools + background-agent delegation (async sub-agents). | OFF |
