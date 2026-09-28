# Bundled plugins

Unlike `agents/`, `skills/`, and `commands/` (which are plain files checked into
this directory), **plugins are built at image-build time**, not stored here. The
third-party plugin code — often with a `node_modules/` — is cloned and vendored
by the `plugins-build` stage in [`../../Dockerfile`](../../Dockerfile) and lands at
`/opt/opencode/bundle/plugins/<name>/` inside the image. This file is the only
thing in this source directory that ships from the repo. First-party plugins
live in `../../plugins/` and are copied by the same build stage, with no
dependency install required for `merge-system`.

## Why plugins are different

- **Required compatibility hook + optional plugins.** `merge-system` is
  always enabled. Other plugins are default-OFF; a developer enables them via the
  `ENABLED_PLUGINS` list in `.env` (space/comma-separated). `disabled.yaml` does
  *not* control plugins — it persists in a volume and would silently override
  `.env`. The entrypoint always links `merge-system` and rebuilds optional
  plugin symlinks to match `ENABLED_PLUGINS`
  on every boot. `/plugins` shows the live state.
- **Loaded by symlink, not by the `plugin` array.** OpenCode auto-scans
  `plugin/*.{ts,js}` in each config dir and imports the files directly (it
  follows symlinks; verified in the 1.16.2 and 1.17.3 binaries). The entrypoint
  symlinks the entry files of *enabled*
  plugins into `~/.config/opencode/plugin/`. We deliberately do **not** put
  entries in `opencode.json`'s `plugin` array — that path makes OpenCode/Bun
  run a network install, which the egress lock blocks. `policy.yaml` also sets
  `BUN_CONFIG_SKIP_INSTALL_PACKAGES=true` and `NPM_CONFIG_OFFLINE=true`.
  The latter prevents OpenCode 1.18.32's npm dependency checks from waiting
  for unreachable registry retries; uncached dependencies fail immediately.
  Plugin imports resolve against each plugin's vendored `node_modules`.

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

Edit the `plugins-build` stage in `../../Dockerfile`: clone at a pinned ref, build
if needed, vendor runtime deps, write an `entries` manifest, and `cp` the result
into `/staging/plugins/<name>/`. For a dependency-free first-party plugin,
check its source and `entries` manifest into `../../plugins/<name>/` and
`COPY` that directory into the same staging path. Record every plugin in
`../../manifest.json` and in the `.env.example`
`ENABLED_PLUGINS` comment, the description + `Source:` URL in
`../commands/plugins.md`, the **canonical provenance row** (name, upstream link,
pinned version) in the [README "Plugins" table](../../../README.md#plugins), and
the table below. Pin by tag or commit SHA — never a moving branch — and re-test
the load on every bump. See
[`../../../docs/ADDING_PLUGINS.md`](../../../docs/ADDING_PLUGINS.md).

## Currently baked

`merge-system` is always on. Others are OFF by default (opt-in via
`ENABLED_PLUGINS`); pinned third-party versions live in
`../../Dockerfile` and the [README table](../../../README.md#plugins).

| Name | What it is | Upstream |
|------|------------|----------|
| `superpowers` | Skills library (brainstorming, writing-plans, systematic-debugging, TDD, code review). Zero deps, zero runtime egress. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — trims stale tool output from the context window to save tokens. | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |
| `opencode-pty` | Interactive PTY management: run background processes in real pseudo-terminals, stream/regex-filter their output, plus a local web viewer. | [shekohex/opencode-pty](https://github.com/shekohex/opencode-pty) |
| `merge-system` | Always on: merges system prompt blocks for the saga vLLM gateway's Qwen3.5 template. | [First-party source](../../plugins/merge-system/merge-system.js) |
