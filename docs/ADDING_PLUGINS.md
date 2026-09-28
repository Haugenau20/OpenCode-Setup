# Plugins: enabling, disabling, and adding

OpenCode plugins are JS/TS modules that hook into the agent's lifecycle (and can
bundle skills/tools). This image ships `merge-system` **always on** for gateway
compatibility, plus optional plugins **baked in but turned OFF**. Loading them
needs **no network**: the code and dependencies are already in the image.

## What's baked in

`merge-system` is required and always **ON**. Others ship **OFF** (opt-in via
`ENABLED_PLUGINS`). Pinned third-party versions and the full
provenance table live in the [README "Plugins" section](../README.md#plugins);
the pins themselves are set in [`../opencode/Dockerfile`](../opencode/Dockerfile).

| Name | What it does | Upstream |
|------|--------------|----------|
| `superpowers` | Skills library — brainstorming, writing-plans, systematic-debugging, TDD, requesting/receiving code review, and more. | [obra/superpowers](https://github.com/obra/superpowers) |
| `dcp` | Dynamic context pruning — silently trims stale tool output from the context window to save tokens. | [Opencode-DCP/opencode-dynamic-context-pruning](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning) |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | [kdcokenny/opencode-workspace](https://github.com/kdcokenny/opencode-workspace) |
| `opencode-pty` | Interactive PTY management: run background processes in real pseudo-terminals, stream/regex-filter their output, plus a local web viewer. | [shekohex/opencode-pty](https://github.com/shekohex/opencode-pty) |
| `merge-system` | Merges multiple system blocks into a single message for saga / Qwen3.5. | [First-party source](../opencode/plugins/merge-system/merge-system.js) |

Run **`/plugins`** in the TUI for the live catalog and current on/off state.

### How to tell a plugin is working

Each plugin surfaces differently — there is no single "plugins" list in the TUI
that shows them (the Ctrl-P plugins dialog only lists `opencode.json` `plugin`
array entries, which we don't use):

- **merge-system** is always on and has no user-facing tools. No `.env`
  change is needed; rebuild/re-pull the image and restart to pick it up.
  It merges nonblank system prompt blocks before the request is built,
  avoiding the saga / Qwen3.5 multi-system-message 500 only for the exact
  `input.model.id` in its guard. Replace the checked-in `"<model>"` placeholder
  with the deployment's model ID before building; all other or missing IDs
  leave messages unchanged. A live request to the gateway is the end-to-end
  check. Remove the plugin once the backend is fixed.
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
- **opencode-pty** adds model-callable tools — `pty_spawn`, `pty_write`,
  `pty_read`, `pty_list`, `pty_kill` — for driving background processes in
  real pseudo-terminals, plus a local web viewer started via the
  `/pty-open-background-spy` slash command. Ask the agent what tools it has,
  or run that command and open the published viewer port (derived from
  `OPENCODE_PORT` as `1<OPENCODE_PORT>`, e.g. `14096`).

## Turning a plugin on or off (developer)

**`merge-system` is always on**, including when `ENABLED_PLUGINS` is empty or
`disabled.yaml` lists it. It cannot be turned off through either setting.

Optional plugins are toggled by **one variable in your host `.env`** —
`ENABLED_PLUGINS` — exactly like every other switch in this system
(`ALLOW_REMOTE_GIT`). It is the **single source of truth**
for optional plugins. No container, no YAML, no shell-in.

```dotenv
# .env (on your host)
ENABLED_PLUGINS=superpowers dcp
```

Then re-run the launcher (or `scripts/opencode`). Names are space- or
comma-separated; available names are `superpowers`, `dcp`, `opencode-workspace`,
and `opencode-pty`. `merge-system` does not need to be listed.
On every boot the entrypoint rebuilds the set from scratch: it removes the
plugin symlinks it manages, always links `merge-system`, and re-creates
optional entries named in `ENABLED_PLUGINS`. To disable an optional plugin,
remove it from the line (or empty the line) and restart. Verify:

```bash
docker exec opencode-<slug> ls -l /home/dev/.config/opencode/plugin/
```

> A restart is always required — OpenCode loads plugins once at startup and has
> no hot-reload. Re-running the launcher *is* the restart, so this is no extra
> step.

> **`disabled.yaml` does NOT control plugins.** That file toggles bundled
> agents/skills/commands/mcp (which ship ON). Optional plugins are driven
> solely by `ENABLED_PLUGINS`; `merge-system` is always on. There is no second
> source of truth hiding in a volume. See [`ADDING_SKILLS.md`](ADDING_SKILLS.md) for the bundle
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
   (`<symlink-name>=<relative/entry/path>` per line). For a dependency-free
   first-party plugin such as `merge-system`, commit its source, `package.json`
   (`type: module`), and `entries` under `opencode/plugins/<name>/`, then
   `COPY` that directory into the same staging path. It is versioned with
   the image rather than an external ref.
2. **List it as available.** New optional plugins are OFF unless named in
   `ENABLED_PLUGINS`. Add the new name to the
   `ENABLED_PLUGINS` comment in [`../.env.example`](../.env.example) so users
   know it exists. Also add it to `plugins[]` in
   [`../opencode/manifest.json`](../opencode/manifest.json) so launchers can
   discover it.
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

- It runs on **Node 22** (or under OpenCode's bundled Bun) — no engine
  requirement newer than what `opencode/Dockerfile`'s `NODE_MAJOR` pins.
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

> **Deliberate exception:** `opencode-pty` bends two of the rules above — it
> runs a local web server (its viewer) and its `open` dependency assumes a
> desktop browser. Both are fine here: the server binds only inside the
> container/compose network (no egress, nothing dials out), and the
> browser-open call silently no-ops in this headless container — the
> developer reaches the viewer through the port `oc-publish` forwards to the
> host instead of a browser opening automatically.
