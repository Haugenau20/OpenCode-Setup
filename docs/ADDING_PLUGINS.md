# Plugins: enabling, disabling, and adding

OpenCode plugins are JS/TS modules that hook into the agent's lifecycle (and can
bundle skills/tools). This image ships a curated set **baked in but turned OFF**
— they are pure opt-in. Enabling one needs **no network**: the code and its
dependencies are already vendored in the image.

## What's baked in

All ship **OFF** (opt-in via `ENABLED_PLUGINS`). Pinned versions and the full
provenance table live in the [README "Plugins" section](../README.md#plugins);
the pins themselves are set in [`../opencode/Dockerfile`](../opencode/Dockerfile).

| Name | What it does | Upstream |
|------|--------------|----------|
| `superpowers` | Skills library — brainstorming, writing-plans, systematic-debugging, TDD, requesting/receiving code review, and more. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens. | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |

Run **`/plugins`** in the TUI for the live catalog and current on/off state.

### How to tell a plugin is working

Each plugin surfaces differently — there is no single "plugins" list in the TUI
that shows them (the Ctrl-P plugins dialog only lists `opencode.json` `plugin`
array entries, which we don't use):

- **superpowers** registers skills and injects a bootstrap — ask *"tell me about
  your superpowers"* or check the skills list.
- **opencode-workspace** adds model-callable tools — `plan_save`, `plan_read`,
  and `delegate*`. Ask the agent what tools it has.
- **dcp** is **invisible by design**. It does **not** add a tool the model can
  call — it works purely through a `chat.messages.transform` hook that *silently
  prunes obsolete tool outputs from the context*, and only once a conversation
  passes a token **threshold**. In a short chat it correctly does nothing, and
  the model will say it has no "compress/prune" tool — that is expected, not a
  failure. To see it act, set `"debug": true` in `~/.config/opencode/dcp.jsonc`,
  restart, run a long tool-heavy session, and watch the log.

  > **Caveat:** dcp relies on `experimental.chat.messages.transform`, which is
  > deprecated upstream. It works today but is the plugin most likely to break
  > on an OpenCode bump — re-test it whenever you change `OPENCODE_VERSION`.

## Turning a plugin on or off (developer)

Plugins are toggled by **one variable in your host `.env`** —
`ENABLED_PLUGINS` — exactly like every other switch in this system
(`ALLOW_REMOTE_GIT`, `ENABLE_SESSION_LOGS`). It is the **single source of truth**
for plugins. No container, no YAML, no shell-in.

```dotenv
# .env (on your host)
ENABLED_PLUGINS=superpowers dcp
```

Then re-run the launcher (or `scripts/opencode`). Names are space- or
comma-separated; available names are `superpowers`, `dcp`, `opencode-workspace`.
On every boot the entrypoint rebuilds the set from scratch: it removes the
plugin symlinks it manages and re-creates only the ones named in
`ENABLED_PLUGINS`. To disable a plugin, remove it from the line (or empty the
line) and restart. Verify:

```bash
docker exec opencode-<slug> ls -l /home/dev/.config/opencode/plugin/
```

> A restart is always required — OpenCode loads plugins once at startup and has
> no hot-reload. Re-running the launcher *is* the restart, so this is no extra
> step.

> **`disabled.yaml` does NOT control plugins.** That file toggles bundled
> agents/skills/commands/mcp (which ship ON). Plugins are opt-in and driven
> solely by `ENABLED_PLUGINS`, so there is no second, persistent source of truth
> hiding in a volume. See [`ADDING_SKILLS.md`](ADDING_SKILLS.md) for the bundle
> toggles.

## Why you can't just paste a GitHub plugin URL

The usual OpenCode instruction — `"plugin": ["foo@git+https://github.com/..."]`
in `opencode.json` — makes OpenCode run a **Bun install at startup**, reaching
out to GitHub/npm. This image's egress is locked to the LLM endpoint, Bitbucket,
and JIRA, so that install would fail. Instead, plugins are vendored at build time
and loaded from local files (OpenCode auto-imports `plugin/*.{ts,js}` from your
config dir). To add a plugin that isn't baked in, it has to go into the
image — see below.

## Adding a plugin to the image (maintainer)

This requires an image rebuild. Open a PR against this repo.

1. **Vendor it at build time.** Add a block to the `plugins-build` stage in
   [`../opencode/Dockerfile`](../opencode/Dockerfile): clone at a **pinned** ref
   (tag or commit SHA — never a moving branch), build if it needs compiling,
   install/prune its **runtime** dependencies, and lay the result out under
   `/staging/plugins/<name>/` with an `entries` manifest
   (`<symlink-name>=<relative/entry/path>` per line).
2. **List it as available.** Plugins are OFF unless named in `ENABLED_PLUGINS`,
   so there's nothing to "default off" — just add the new name to the
   `ENABLED_PLUGINS` comment in [`../.env.example`](../.env.example) so users
   know it exists.
3. **Make it discoverable + traceable.** Add a row (name, description, upstream
   link, pinned version) to the [README "Plugins" table](../README.md#plugins)
   — the canonical provenance — and add the name + description + `Source:` URL to
   the map in
   [`../opencode/bundle/commands/plugins.md`](../opencode/bundle/commands/plugins.md)
   (so `/plugins` shows it in the TUI). Also add a row to the tables in this
   doc and in
   [`../opencode/bundle/plugins/README.md`](../opencode/bundle/plugins/README.md).

The entrypoint does the rest: at start it symlinks the entry files of every
*enabled* plugin into `~/.config/opencode/plugin/`, and OpenCode imports them
directly. Imports resolve against the entry file's real path, so a vendored
`node_modules/` next to it is found automatically.

### Offline ground rules for a candidate plugin

A plugin is a clean fit only if **all** of these hold:

- It runs on **Node 20** (or under OpenCode's bundled Bun) — no `>=22` engine.
- It makes **no required network calls at runtime** (a best-effort,
  failure-tolerant version check is fine; a hard dependency on an external API
  or model download is not). Disable any auto-update — e.g. `dcp` ships a seeded
  `dcp.jsonc` with `"autoUpdate": false`.
- Its dependencies can be **fully vendored** at build time (no runtime
  `npm install`, no native addon whose ABI won't match the runtime).
- It doesn't assume host capabilities the sandbox lacks (spawning terminals or
  sibling containers, desktop notifications, multiple worktrees, etc.). This is
  why only two of `opencode-workspace`'s four plugins are baked.

If a plugin needs live egress to function, it does **not** belong here — flag it
for a deliberate allowlist decision instead.
